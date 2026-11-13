import "dart:convert";
import "dart:io";

import "package:droid_edge_server/models/request_log_entry.dart";
import "package:droid_edge_server/models/telemetry_snapshot.dart";
import "package:droid_edge_server/server/edge_http_server.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  group("EdgeHttpServer", () {
    late EdgeHttpServer server;

    setUp(() {
      server = EdgeHttpServer();
    });

    tearDown(() async {
      await server.dispose();
    });

    test("serves GET /v1/health and emits RequestLogEntry", () async {
      final logs = <RequestLogEntry>[];
      final sub = server.requestLogs.listen(logs.add);
      addTearDown(sub.cancel);

      final port = await server.start(port: 0);
      expect(server.isRunning, isTrue);
      expect(port, greaterThan(0));

      final client = HttpClient();
      addTearDown(client.close);

      final request = await client.get("127.0.0.1", port, "/v1/health");
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers.contentType?.mimeType, "application/json");

      final jsonBody = jsonDecode(body) as Map<String, dynamic>;
      expect(jsonBody["status"], "ok");
      expect(jsonBody["uptime_seconds"], isA<int>());
      expect(jsonBody["timestamp"], isA<String>());

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(logs, hasLength(1));
      expect(logs.first.method, "GET");
      expect(logs.first.path, "/v1/health");
      expect(logs.first.statusCode, 200);
      expect(logs.first.latencyMs, greaterThanOrEqualTo(0));
    });

    test("returns 404 JSON for unknown routes and logs 404", () async {
      final logs = <RequestLogEntry>[];
      final sub = server.requestLogs.listen(logs.add);
      addTearDown(sub.cancel);

      final port = await server.start(port: 0);
      final client = HttpClient();
      addTearDown(client.close);

      final request = await client.get("127.0.0.1", port, "/unknown");
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();

      expect(response.statusCode, HttpStatus.notFound);
      final jsonBody = jsonDecode(body) as Map<String, dynamic>;
      expect(jsonBody["error"], "not_found");

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(logs, hasLength(1));
      expect(logs.first.statusCode, 404);
      expect(logs.first.path, "/unknown");
    });

    test("serves GET /v1/status with telemetry payload", () async {
      final statusServer = EdgeHttpServer(
        telemetryProvider: () => TelemetrySnapshot(
          batteryLevel: 88,
          batteryState: "charging",
          networkType: "wifi",
          thermalStatus: "none",
          batteryTemperatureCelsius: 30.5,
          timestamp: DateTime.utc(2026, 11, 12, 12, 0, 0),
        ),
      );
      addTearDown(statusServer.dispose);

      final port = await statusServer.start(port: 0);
      final client = HttpClient();
      addTearDown(client.close);

      final request = await client.get("127.0.0.1", port, "/v1/status");
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();

      expect(response.statusCode, HttpStatus.ok);
      final jsonBody = jsonDecode(body) as Map<String, dynamic>;
      expect(jsonBody["status"], "ok");
      expect(jsonBody["hostname"], "android-edge.local");
      expect(jsonBody["port"], port);

      final telemetry = jsonBody["telemetry"] as Map<String, dynamic>;
      expect(telemetry["battery_percent"], 88);
      expect(telemetry["battery_state"], "charging");
      expect(telemetry["is_charging"], isTrue);
      expect(telemetry["network_type"], "wifi");
      expect(telemetry["thermal_status"], "none");
      expect(telemetry["battery_temperature_c"], 30.5);
    });
  });
}

