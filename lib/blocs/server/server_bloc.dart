import "package:flutter_bloc/flutter_bloc.dart";

import "../../server/edge_http_server.dart";
import "../../services/foreground_service_manager.dart";
import "../../services/mdns_service.dart";
import "../../services/network_info_service.dart";
import "server_event.dart";
import "server_state.dart";

class ServerBloc extends Bloc<ServerEvent, ServerState> {
  ServerBloc({
    required this.httpServer,
    required this.networkInfoService,
    ForegroundServiceManager? foregroundServiceManager,
    MdnsService? mdnsService,
  })  : foregroundServiceManager =
            foregroundServiceManager ?? ForegroundServiceManager(),
        mdnsService = mdnsService ?? MdnsService(),
        super(const ServerState()) {
    on<ServerStartRequested>(_onStartRequested);
    on<ServerStopRequested>(_onStopRequested);
    on<ServerIpRefreshRequested>(_onIpRefreshRequested);
    on<ServerBatteryOptimizationChecked>(_onBatteryOptimizationChecked);
    on<ServerBatteryOptimizationRequested>(_onBatteryOptimizationRequested);
  }

  final EdgeHttpServer httpServer;
  final NetworkInfoService networkInfoService;
  final ForegroundServiceManager foregroundServiceManager;
  final MdnsService mdnsService;

  Future<void> _onStartRequested(
    ServerStartRequested event,
    Emitter<ServerState> emit,
  ) async {
    if (state.isRunning || state.isBusy) return;

    emit(
      state.copyWith(
        status: ServerStatusKind.starting,
        port: event.port,
        clearError: true,
      ),
    );

    try {
      final ip = await networkInfoService.getLocalIpAddress();
      final boundPort = await httpServer.start(port: event.port);

      await foregroundServiceManager.start(
        ipAddress: ip,
        port: boundPort,
        hostname: mdnsService.hostname,
      );
      await mdnsService.start(ipAddress: ip, port: boundPort);
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
          clearError: true,
        ),
      );
    } catch (error) {
      await mdnsService.stop();
      await foregroundServiceManager.stop();
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
      await mdnsService.start(ipAddress: ip, port: state.port);
      await foregroundServiceManager.start(
        ipAddress: ip,
        port: state.port,
        hostname: mdnsService.hostname,
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
