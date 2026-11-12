import "dart:async";
import "dart:convert";
import "dart:io";

import "package:shelf/shelf.dart";
import "package:shelf/shelf_io.dart" as shelf_io;
import "package:shelf_router/shelf_router.dart";

import "../models/request_log_entry.dart";
import "routes/health_routes.dart";

/// Embedded HTTP server built on `shelf` and `shelf_router`.
///
/// Kept independent of the UI and BLoC layers; publishes a [RequestLogEntry]
/// to [requestLogs] for each handled request.
class EdgeHttpServer {
  EdgeHttpServer();

  HttpServer? _server;
  DateTime? _startedAt;
  int _requestCounter = 0;

  final StreamController<RequestLogEntry> _logController =
      StreamController<RequestLogEntry>.broadcast();

  Stream<RequestLogEntry> get requestLogs => _logController.stream;

  bool get isRunning => _server != null;
  int? get boundPort => _server?.port;
  DateTime? get startedAt => _startedAt;

  int get uptimeSeconds {
    final started = _startedAt;
    if (started == null) return 0;
    return DateTime.now().difference(started).inSeconds;
  }

  /// Begins listening on `0.0.0.0:<port>` and returns the bound port
  /// (handy when passing `port: 0` in tests).
  Future<int> start({int port = 8080}) async {
    if (_server != null) {
      return _server!.port;
    }

    final rootRouter = Router();
    final healthRoutes = HealthRoutes(
      uptimeSecondsProvider: () => uptimeSeconds,
    );
    rootRouter.mount("/", healthRoutes.router.call);

    final handler = const Pipeline()
        .addMiddleware(_requestLoggingMiddleware())
        .addHandler((Request request) async {
      final response = await rootRouter.call(request);
      if (response.statusCode == 404 &&
          response.headers["content-type"] == null) {
        return Response.notFound(
          jsonEncode({
            "error": "not_found",
            "path": "/${request.url.path}",
          }),
          headers: const {"content-type": "application/json; charset=utf-8"},
        );
      }
      return response;
    });

    _startedAt = DateTime.now();
    try {
      _server = await shelf_io.serve(
        handler,
        InternetAddress.anyIPv4,
        port,
        shared: true,
      );
      return _server!.port;
    } catch (_) {
      _startedAt = null;
      rethrow;
    }
  }

  /// Shuts down the HTTP server.
  Future<void> stop() async {
    final server = _server;
    _server = null;
    _startedAt = null;
    if (server != null) {
      await server.close(force: true);
    }
  }

  Future<void> dispose() async {
    await stop();
    await _logController.close();
  }

  Middleware _requestLoggingMiddleware() {
    return (Handler innerHandler) {
      return (Request request) async {
        final stopwatch = Stopwatch()..start();
        final connectionInfo =
            request.context["shelf.io.connection_info"] as HttpConnectionInfo?;
        final remoteIp = connectionInfo?.remoteAddress.address;

        Response response;
        try {
          response = await innerHandler(request);
        } catch (error) {
          response = Response.internalServerError(
            body: jsonEncode({
              "error": "internal_server_error",
              "message": error.toString(),
            }),
            headers: const {"content-type": "application/json; charset=utf-8"},
          );
        } finally {
          stopwatch.stop();
        }

        _requestCounter++;
        final normalizedPath =
            request.requestedUri.path.isEmpty ? "/" : request.requestedUri.path;

        if (!_logController.isClosed) {
          _logController.add(
            RequestLogEntry(
              id: "${DateTime.now().microsecondsSinceEpoch}-$_requestCounter",
              timestamp: DateTime.now(),
              method: request.method,
              path: normalizedPath,
              statusCode: response.statusCode,
              latencyMs: stopwatch.elapsedMilliseconds,
              remoteIp: remoteIp,
            ),
          );
        }

        return response;
      };
    };
  }
}

