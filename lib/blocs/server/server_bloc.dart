import "dart:async";
import "dart:io";

import "package:connectivity_plus/connectivity_plus.dart";
import "package:flutter_bloc/flutter_bloc.dart";

import "../../server/edge_http_server.dart";
import "../../services/foreground_service_manager.dart";
import "../../services/local_ca_service.dart";
import "../../services/mdns_service.dart";
import "../../services/network_info_service.dart";
import "../../services/pairing_token_service.dart";
import "server_event.dart";
import "server_state.dart";

class ServerBloc extends Bloc<ServerEvent, ServerState> {
  ServerBloc({
    required this.httpServer,
    required this.networkInfoService,
    ForegroundServiceManager? foregroundServiceManager,
    MdnsService? mdnsService,
    PairingTokenService? pairingTokenService,
    LocalCaService? localCaService,
    this.enableTls = true,
  })  : foregroundServiceManager =
            foregroundServiceManager ?? ForegroundServiceManager(),
        mdnsService = mdnsService ?? MdnsService(),
        pairingTokenService = pairingTokenService ?? PairingTokenService(),
        localCaService = localCaService ?? LocalCaService(),
        super(ServerState(tlsEnabled: enableTls)) {
    on<ServerStartRequested>(_onStartRequested);
    on<ServerStopRequested>(_onStopRequested);
    on<ServerIpRefreshRequested>(_onIpRefreshRequested);
    on<ServerBatteryOptimizationChecked>(_onBatteryOptimizationChecked);
    on<ServerBatteryOptimizationRequested>(_onBatteryOptimizationRequested);
    on<ServerSecurityInitialized>(_onSecurityInitialized);
    on<ServerTokenRotateRequested>(_onTokenRotateRequested);

    _connectivitySub = networkInfoService.onConnectivityChanged.listen(
      (_) {
        _connectivityDebounce?.cancel();
        _connectivityDebounce = Timer(const Duration(milliseconds: 500), () {
          if (!isClosed && state.isRunning) {
            add(const ServerIpRefreshRequested());
          }
        });
      },
      onError: (_) {},
    );
  }

  final EdgeHttpServer httpServer;
  final NetworkInfoService networkInfoService;
  final ForegroundServiceManager foregroundServiceManager;
  final MdnsService mdnsService;
  final PairingTokenService pairingTokenService;
  final LocalCaService localCaService;
  final bool enableTls;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _connectivityDebounce;

  @override
  Future<void> close() async {
    _connectivityDebounce?.cancel();
    await _connectivitySub?.cancel();
    return super.close();
  }

  Future<({String token, String caCertPem, String caFingerprint})>
      _ensureSecurityMaterial() async {
    final token = state.pairingToken.isNotEmpty
        ? state.pairingToken
        : await pairingTokenService.getOrCreateToken();
    httpServer.updateAuthToken(token);

    if (!enableTls) {
      return (
        token: token,
        caCertPem: state.caCertPem,
        caFingerprint: state.caFingerprintSha256,
      );
    }

    if (state.caCertPem.isNotEmpty && state.caFingerprintSha256.isNotEmpty) {
      return (
        token: token,
        caCertPem: state.caCertPem,
        caFingerprint: state.caFingerprintSha256,
      );
    }

    final ca = await localCaService.getOrCreateCa();
    return (
      token: token,
      caCertPem: ca.caCertPem,
      caFingerprint: ca.caFingerprintSha256,
    );
  }

  Future<void> _onSecurityInitialized(
    ServerSecurityInitialized event,
    Emitter<ServerState> emit,
  ) async {
    final sec = await _ensureSecurityMaterial();
    emit(
      state.copyWith(
        tlsEnabled: enableTls,
        pairingToken: sec.token,
        caCertPem: sec.caCertPem,
        caFingerprintSha256: sec.caFingerprint,
      ),
    );
  }

  Future<void> _onTokenRotateRequested(
    ServerTokenRotateRequested event,
    Emitter<ServerState> emit,
  ) async {
    final rotated = await pairingTokenService.rotateToken();
    httpServer.updateAuthToken(rotated);
    emit(state.copyWith(pairingToken: rotated));
  }

  Future<void> _onStartRequested(
    ServerStartRequested event,
    Emitter<ServerState> emit,
  ) async {
    if (state.isRunning || state.isBusy) return;

    emit(
      state.copyWith(
        status: ServerStatusKind.starting,
        port: event.port,
        tlsEnabled: enableTls,
        clearError: true,
      ),
    );

    try {
      final sec = await _ensureSecurityMaterial();
      final ip = await networkInfoService.getLocalIpAddress();

      SecurityContext? tlsContext;
      var caCertPem = sec.caCertPem;
      var caFingerprint = sec.caFingerprint;
      if (enableTls) {
        final bundle = await localCaService.mintTlsBundle(
          ipAddresses: [ip, "127.0.0.1"],
          hostname: mdnsService.hostname,
        );
        tlsContext = localCaService.buildServerSecurityContext(bundle);
        caCertPem = bundle.caCertPem;
        caFingerprint = bundle.caFingerprintSha256;
      }

      final boundPort = await httpServer.start(
        port: event.port,
        bindAddress: ip,
        bindLoopback: true,
        securityContext: tlsContext,
        authToken: sec.token,
        allowedHosts: {
          ip,
          "127.0.0.1",
          "localhost",
          mdnsService.hostname,
        },
      );

      await foregroundServiceManager.start(
        ipAddress: ip,
        port: boundPort,
        hostname: mdnsService.hostname,
        tlsEnabled: enableTls,
      );
      await mdnsService.start(
        ipAddress: ip,
        port: boundPort,
        tlsEnabled: enableTls,
      );
      final batteryIgnored =
          await foregroundServiceManager.isIgnoringBatteryOptimizations();

      emit(
        state.copyWith(
          status: ServerStatusKind.running,
          ipAddress: ip,
          port: boundPort,
          startedAt: httpServer.startedAt ?? DateTime.now(),
          mdnsHostname: mdnsService.hostname,
          mdnsActive: mdnsService.isRunning,
          batteryOptimizationIgnored: batteryIgnored,
          tlsEnabled: enableTls,
          pairingToken: sec.token,
          caCertPem: caCertPem,
          caFingerprintSha256: caFingerprint,
          clearError: true,
        ),
      );
    } catch (error) {
      await mdnsService.stop();
      await foregroundServiceManager.stop();
      await httpServer.stop();
      emit(
        state.copyWith(
          status: ServerStatusKind.error,
          mdnsActive: false,
          clearStartedAt: true,
          errorMessage: "Failed to start server on port ${event.port}: $error",
        ),
      );
    }
  }

  Future<void> _onStopRequested(
    ServerStopRequested event,
    Emitter<ServerState> emit,
  ) async {
    if (!state.isRunning && state.status != ServerStatusKind.error) return;

    emit(state.copyWith(status: ServerStatusKind.stopping, clearError: true));
    try {
      await mdnsService.stop();
      await foregroundServiceManager.stop();
      await httpServer.stop();
      emit(
        state.copyWith(
          status: ServerStatusKind.stopped,
          mdnsActive: false,
          clearStartedAt: true,
          clearError: true,
        ),
      );
    } catch (error) {
      emit(
        state.copyWith(
          status: ServerStatusKind.error,
          errorMessage: "Failed to stop server: $error",
        ),
      );
    }
  }

  Future<void> _onIpRefreshRequested(
    ServerIpRefreshRequested event,
    Emitter<ServerState> emit,
  ) async {
    final ip = await networkInfoService.getLocalIpAddress();
    if (state.isRunning) {
      if (ip != state.ipAddress) {
        try {
          await httpServer.stop();
          SecurityContext? tlsContext;
          var caCertPem = state.caCertPem;
          var caFingerprint = state.caFingerprintSha256;
          if (enableTls) {
            final bundle = await localCaService.mintTlsBundle(
              ipAddresses: [ip, "127.0.0.1"],
              hostname: mdnsService.hostname,
            );
            tlsContext = localCaService.buildServerSecurityContext(bundle);
            caCertPem = bundle.caCertPem;
            caFingerprint = bundle.caFingerprintSha256;
          }

          final reboundPort = await httpServer.start(
            port: state.port,
            bindAddress: ip,
            bindLoopback: true,
            securityContext: tlsContext,
            authToken:
                state.pairingToken.isNotEmpty ? state.pairingToken : null,
            allowedHosts: {
              ip,
              "127.0.0.1",
              "localhost",
              mdnsService.hostname,
            },
          );

          await mdnsService.start(
            ipAddress: ip,
            port: reboundPort,
            tlsEnabled: enableTls,
          );
          await foregroundServiceManager.start(
            ipAddress: ip,
            port: reboundPort,
            hostname: mdnsService.hostname,
            tlsEnabled: enableTls,
          );
          emit(
            state.copyWith(
              ipAddress: ip,
              port: reboundPort,
              caCertPem: caCertPem,
              caFingerprintSha256: caFingerprint,
            ),
          );
          return;
        } catch (error) {
          emit(
            state.copyWith(
              status: ServerStatusKind.error,
              mdnsActive: false,
              clearStartedAt: true,
              errorMessage: "Failed to rebind server on IP $ip: $error",
            ),
          );
          return;
        }
      }

      await mdnsService.start(
        ipAddress: ip,
        port: state.port,
        tlsEnabled: enableTls,
      );
      await foregroundServiceManager.start(
        ipAddress: ip,
        port: state.port,
        hostname: mdnsService.hostname,
        tlsEnabled: enableTls,
      );
    }
    emit(state.copyWith(ipAddress: ip));
  }

  Future<void> _onBatteryOptimizationChecked(
    ServerBatteryOptimizationChecked event,
    Emitter<ServerState> emit,
  ) async {
    final ignored =
        await foregroundServiceManager.isIgnoringBatteryOptimizations();
    emit(state.copyWith(batteryOptimizationIgnored: ignored));
  }

  Future<void> _onBatteryOptimizationRequested(
    ServerBatteryOptimizationRequested event,
    Emitter<ServerState> emit,
  ) async {
    final granted =
        await foregroundServiceManager.requestIgnoreBatteryOptimization();
    emit(state.copyWith(batteryOptimizationIgnored: granted));
  }
}
