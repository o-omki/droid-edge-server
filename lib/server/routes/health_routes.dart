import "dart:convert";

import "package:shelf/shelf.dart";
import "package:shelf_router/shelf_router.dart";

/// Defines the health-check route (`GET /v1/health`).
class HealthRoutes {
  HealthRoutes({required this.uptimeSecondsProvider});

  final int Function() uptimeSecondsProvider;

  Router get router {
    final router = Router();
    router.get("/v1/health", _handleHealth);
    return router;
  }

  Response _handleHealth(Request request) {
    final payload = {
      "status": "ok",
      "uptime_seconds": uptimeSecondsProvider(),
      "timestamp": DateTime.now().toUtc().toIso8601String(),
    };
    return Response.ok(
      jsonEncode(payload),
      headers: const {"content-type": "application/json; charset=utf-8"},
    );
  }
}

