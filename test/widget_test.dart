import "dart:async";

import "package:droid_edge_server/app.dart";
import "package:droid_edge_server/models/request_log_entry.dart";
import "package:droid_edge_server/server/edge_http_server.dart";
import "package:droid_edge_server/services/foreground_service_manager.dart";
import "package:droid_edge_server/services/mdns_service.dart";
import "package:droid_edge_server/services/network_info_service.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

class _FakeNetworkInfoService extends NetworkInfoService {
  @override
  Future<String> getLocalIpAddress() async => "192.168.1.42";
}

class _FakeForegroundServiceManager extends ForegroundServiceManager {
  @override
  Future<void> start({
    required String ipAddress,
    required int port,
    String hostname = "android-edge.local",
  }) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<bool> isIgnoringBatteryOptimizations() async => true;
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

class _FakeEdgeHttpServer extends EdgeHttpServer {
  final StreamController<RequestLogEntry> _controller =
      StreamController<RequestLogEntry>.broadcast();

  bool _running = false;
  DateTime? _startedAt;

  void emitLog(RequestLogEntry entry) {
    _controller.add(entry);
  }

  @override
  Stream<RequestLogEntry> get requestLogs => _controller.stream;

  @override
  bool get isRunning => _running;

  @override
  DateTime? get startedAt => _startedAt;

  @override
  Future<int> start({int port = 8080}) async {
    _running = true;
    _startedAt = DateTime.now();
    return port == 0 ? 8080 : port;
  }

  @override
  Future<void> stop() async {
    _running = false;
    _startedAt = null;
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}

void main() {
  testWidgets("Dashboard renders Material 3 shell and toggles server", (
    WidgetTester tester,
  ) async {
    final server = _FakeEdgeHttpServer();
    addTearDown(server.dispose);

    await tester.pumpWidget(
      DroidEdgeApp(
        httpServer: server,
        networkInfoService: _FakeNetworkInfoService(),
        foregroundServiceManager: _FakeForegroundServiceManager(),
        mdnsService: _FakeMdnsService(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text("Droid Edge Server"), findsOneWidget);
    expect(find.text("Stopped"), findsOneWidget);
    expect(find.text("Start Server"), findsOneWidget);
    expect(find.text("http://192.168.1.42:8080"), findsOneWidget);
    expect(find.text("Device Telemetry & Discovery"), findsOneWidget);

    await tester.tap(find.text("Start Server"));
    await tester.pumpAndSettle();

    expect(find.text("Running"), findsOneWidget);
    expect(find.text("Stop Server"), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text("Waiting for HTTP requests"),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text("Waiting for HTTP requests"), findsOneWidget);

    server.emitLog(
      RequestLogEntry(
        id: "1",
        timestamp: DateTime(2026, 11, 12, 16, 0, 0),
        method: "GET",
        path: "/v1/health",
        statusCode: 200,
        latencyMs: 3,
        remoteIp: "192.168.1.10",
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text("/v1/health"),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text("/v1/health"), findsOneWidget);
    expect(find.text("1"), findsOneWidget);

    await tester.tap(find.text("Clear"));
    await tester.pumpAndSettle();

    expect(find.text("Waiting for HTTP requests"), findsOneWidget);
    expect(find.text("0"), findsOneWidget);

    await tester.ensureVisible(find.text("Stop Server"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Stop Server"));
    await tester.pumpAndSettle();

    expect(find.text("Stopped"), findsOneWidget);
  });
}
