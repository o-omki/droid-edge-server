import "package:droid_edge_server/blocs/server/server_bloc.dart";
import "package:droid_edge_server/blocs/server/server_event.dart";
import "package:droid_edge_server/blocs/server/server_state.dart";
import "package:droid_edge_server/server/edge_http_server.dart";
import "package:droid_edge_server/services/foreground_service_manager.dart";
import "package:droid_edge_server/services/mdns_service.dart";
import "package:droid_edge_server/services/network_info_service.dart";
import "package:flutter_test/flutter_test.dart";

class _FakeNetworkInfoService extends NetworkInfoService {
  @override
  Future<String> getLocalIpAddress() async => "192.168.1.42";
}

class _FakeForegroundServiceManager extends ForegroundServiceManager {
  bool started = false;
  bool ignoringBattery = false;

  @override
  Future<void> start({
    required String ipAddress,
    required int port,
    String hostname = "android-edge.local",
  }) async {
    started = true;
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

  @override
  bool get isRunning => _running;

  @override
  Future<void> start({required String ipAddress, required int port}) async {
    _running = true;
  }

  @override
  Future<void> stop() async {
    _running = false;
  }
}

void main() {
  group("ServerBloc", () {
    late EdgeHttpServer httpServer;
    late _FakeForegroundServiceManager foregroundManager;
    late _FakeMdnsService mdnsService;
    late ServerBloc bloc;

    setUp(() {
      httpServer = EdgeHttpServer();
      foregroundManager = _FakeForegroundServiceManager();
      mdnsService = _FakeMdnsService();
      bloc = ServerBloc(
        httpServer: httpServer,
        networkInfoService: _FakeNetworkInfoService(),
        foregroundServiceManager: foregroundManager,
        mdnsService: mdnsService,
      );
    });

    tearDown(() async {
      await bloc.close();
      await httpServer.dispose();
    });

    test("starts and stops foreground service and mDNS with HTTP server",
        () async {
      bloc.add(const ServerStartRequested(port: 0));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bloc.state.status, ServerStatusKind.running);
      expect(bloc.state.ipAddress, "192.168.1.42");
      expect(bloc.state.port, greaterThan(0));
      expect(bloc.state.mdnsActive, isTrue);
      expect(bloc.state.batteryOptimizationIgnored, isFalse);
      expect(foregroundManager.started, isTrue);

      bloc.add(const ServerBatteryOptimizationRequested());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(bloc.state.batteryOptimizationIgnored, isTrue);

      bloc.add(const ServerStopRequested());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bloc.state.status, ServerStatusKind.stopped);
      expect(bloc.state.mdnsActive, isFalse);
      expect(foregroundManager.started, isFalse);
    });
  });
}

