import "dart:async";
import "dart:io";

import "package:connectivity_plus/connectivity_plus.dart";
import "package:droid_edge_server/blocs/server/server_bloc.dart";
import "package:droid_edge_server/blocs/server/server_event.dart";
import "package:droid_edge_server/blocs/server/server_state.dart";
import "package:droid_edge_server/server/edge_http_server.dart";
import "package:droid_edge_server/services/foreground_service_manager.dart";
import "package:droid_edge_server/services/local_ca_service.dart";
import "package:droid_edge_server/services/mdns_service.dart";
import "package:droid_edge_server/services/network_info_service.dart";
import "package:droid_edge_server/services/pairing_token_service.dart";
import "package:droid_edge_server/services/secure_key_store.dart";
import "package:flutter_test/flutter_test.dart";

class _FakeNetworkInfoService extends NetworkInfoService {
  String currentIp = "127.0.0.1";
  final StreamController<List<ConnectivityResult>> connectivityController =
      StreamController<List<ConnectivityResult>>.broadcast();

  @override
  Future<String> getLocalIpAddress() async => currentIp;

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      connectivityController.stream;
}

class _FakeForegroundServiceManager extends ForegroundServiceManager {
  bool started = false;
  bool ignoringBattery = false;
  bool? lastTlsEnabled;

  @override
  Future<void> start({
    required String ipAddress,
    required int port,
    String hostname = "android-edge.local",
    bool tlsEnabled = true,
  }) async {
    started = true;
    lastTlsEnabled = tlsEnabled;
  }

  @override
  Future<void> stop() async {
    started = false;
  }

  @override
  Future<bool> isIgnoringBatteryOptimizations() async => ignoringBattery;

  @override
  Future<bool> requestIgnoreBatteryOptimization() async {
    ignoringBattery = true;
    return true;
  }
}

class _FakeMdnsService extends MdnsService {
  bool _running = false;
  bool? lastTlsEnabled;

  @override
  bool get isRunning => _running;

  @override
  Future<void> start({
    required String ipAddress,
    required int port,
    bool tlsEnabled = true,
  }) async {
    _running = true;
    lastTlsEnabled = tlsEnabled;
  }

  @override
  Future<void> stop() async {
    _running = false;
  }
}

class _SpyEdgeHttpServer extends EdgeHttpServer {
  final List<String> startBindAddresses = <String>[];
  final List<Set<String>> startAllowedHosts = <Set<String>>[];
  int stopCount = 0;

  @override
  Future<int> start({
    int port = 8080,
    String bindAddress = "127.0.0.1",
    bool bindLoopback = true,
    SecurityContext? securityContext,
    String? authToken,
    Set<String>? allowedHosts,
    Set<String>? allowedOrigins,
  }) {
    startBindAddresses.add(bindAddress);
    startAllowedHosts.add(allowedHosts ?? const <String>{});
    // Bind real socket to 127.0.0.1 on host tests while recording requested LAN IP.
    return super.start(
      port: port == 0 ? 0 : port,
      bindAddress: "127.0.0.1",
      bindLoopback: false,
      securityContext: securityContext,
      authToken: authToken,
      allowedHosts: {
        bindAddress,
        ...?allowedHosts,
      },
      allowedOrigins: allowedOrigins,
    );
  }

  @override
  Future<void> stop() {
    stopCount++;
    return super.stop();
  }
}

void main() {
  group("ServerBloc", () {
    late EdgeHttpServer httpServer;
    late _FakeNetworkInfoService networkInfoService;
    late _FakeForegroundServiceManager foregroundManager;
    late _FakeMdnsService mdnsService;
    late InMemorySecureKeyStore keyStore;
    late ServerBloc bloc;

    setUp(() {
      httpServer = EdgeHttpServer();
      networkInfoService = _FakeNetworkInfoService();
      foregroundManager = _FakeForegroundServiceManager();
      mdnsService = _FakeMdnsService();
      keyStore = InMemorySecureKeyStore();
      bloc = ServerBloc(
        httpServer: httpServer,
        networkInfoService: networkInfoService,
        foregroundServiceManager: foregroundManager,
        mdnsService: mdnsService,
        pairingTokenService: PairingTokenService(keyStore: keyStore),
        localCaService: LocalCaService(keyStore: keyStore),
      );
    });

    tearDown(() async {
      await bloc.close();
      await networkInfoService.connectivityController.close();
      await httpServer.dispose();
    });

    test(
        "starts with TLS + pairing token, rotates token, and stops cleanly",
        () async {
      bloc.add(const ServerSecurityInitialized());
      await Future<void>.delayed(const Duration(milliseconds: 120));

      final initialToken = bloc.state.pairingToken;
      expect(initialToken, startsWith(PairingTokenService.tokenPrefix));
      expect(bloc.state.caFingerprintSha256, isNotEmpty);
      expect(bloc.state.caCertPem, contains("BEGIN CERTIFICATE"));

      bloc.add(const ServerStartRequested(port: 0));
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(bloc.state.status, ServerStatusKind.running);
      expect(bloc.state.ipAddress, "127.0.0.1");
      expect(bloc.state.port, greaterThan(0));
      expect(bloc.state.tlsEnabled, isTrue);
      expect(bloc.state.baseUrl, startsWith("https://127.0.0.1:"));
      expect(bloc.state.mdnsActive, isTrue);
      expect(bloc.state.batteryOptimizationIgnored, isFalse);
      expect(foregroundManager.started, isTrue);
      expect(foregroundManager.lastTlsEnabled, isTrue);
      expect(mdnsService.lastTlsEnabled, isTrue);
      expect(httpServer.isTlsEnabled, isTrue);

      bloc.add(const ServerTokenRotateRequested());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(bloc.state.pairingToken, isNot(equals(initialToken)));
      expect(httpServer.authToken, equals(bloc.state.pairingToken));

      bloc.add(const ServerBatteryOptimizationRequested());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(bloc.state.batteryOptimizationIgnored, isTrue);

      bloc.add(const ServerStopRequested());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bloc.state.status, ServerStatusKind.stopped);
      expect(bloc.state.mdnsActive, isFalse);
      expect(foregroundManager.started, isFalse);
    });

    test(
        "cleanly rebinds server and preserves Root CA when connectivity/DHCP IP changes",
        () async {
      final spyServer = _SpyEdgeHttpServer();
      final rebindNetwork = _FakeNetworkInfoService()
        ..currentIp = "192.168.1.42";
      final rebindKeyStore = InMemorySecureKeyStore();
      final rebindBloc = ServerBloc(
        httpServer: spyServer,
        networkInfoService: rebindNetwork,
        foregroundServiceManager: foregroundManager,
        mdnsService: mdnsService,
        pairingTokenService: PairingTokenService(keyStore: rebindKeyStore),
        localCaService: LocalCaService(keyStore: rebindKeyStore),
      );
      addTearDown(() async {
        await rebindBloc.close();
        await rebindNetwork.connectivityController.close();
        await spyServer.dispose();
      });

      rebindBloc.add(const ServerStartRequested(port: 0));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(rebindBloc.state.ipAddress, "192.168.1.42");
      final originalCaFingerprint = rebindBloc.state.caFingerprintSha256;
      expect(spyServer.startBindAddresses, ["192.168.1.42"]);

      // Simulate DHCP renewal / Wi-Fi reconnect to a new LAN IP.
      rebindNetwork.currentIp = "192.168.1.99";
      rebindNetwork.connectivityController.add([ConnectivityResult.wifi]);
      await Future<void>.delayed(const Duration(milliseconds: 700));

      expect(rebindBloc.state.ipAddress, "192.168.1.99");
      expect(rebindBloc.state.caFingerprintSha256, originalCaFingerprint);
      expect(spyServer.stopCount, greaterThanOrEqualTo(1));
      expect(spyServer.startBindAddresses, ["192.168.1.42", "192.168.1.99"]);
      expect(spyServer.startAllowedHosts.last, contains("192.168.1.99"));
    });
  });
}
