import "dart:async";
import "dart:convert";

import "package:shelf/shelf.dart";
import "package:shelf_router/shelf_router.dart";

import "../../models/telemetry_snapshot.dart";

class StatusRoutes {
  StatusRoutes({
    required this.uptimeSecondsProvider,
    required this.boundPortProvider,
    required this.telemetryProvider,
    this.hostname = "android-edge.local",
  });

  final int Function() uptimeSecondsProvider;
  final int? Function() boundPortProvider;
  final FutureOr<TelemetrySnapshot> Function() telemetryProvider;
  final String hostname;

  Router get router {
    final router = Router();
    router.get("/v1/status", _handleStatus);
    return router;
  }

  Future<Response> _handleStatus(Request request) async {
    final telemetry = await telemetryProvider();
    final payload = {
      "status": "ok",
      "hostname": hostname,
      "port": boundPortProvider(),
      "uptime_seconds": uptimeSecondsProvider(),
      "timestamp": DateTime.now().toUtc().toIso8601String(),
      "telemetry": telemetry.toJson(),
    };
    return Response.ok(
      jsonEncode(payload),
      headers: const {"content-type": "application/json; charset=utf-8"},
    );
  }
}

