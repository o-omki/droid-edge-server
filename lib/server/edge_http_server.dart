import "dart:async";
import "dart:convert";
import "dart:io";

import "package:shelf/shelf.dart";
import "package:shelf/shelf_io.dart" as shelf_io;
import "package:shelf_router/shelf_router.dart";

import "../engines/barcode_engine.dart";
import "../engines/entity_extraction_engine.dart";
import "../engines/face_detection_engine.dart";
import "../engines/litert_lm_engine.dart";
import "../engines/local_genai_engine.dart";
import "../engines/ocr_engine.dart";
import "../engines/pdf_rasterizer.dart";
import "../engines/pii_redaction_engine.dart";
import "../engines/searchable_pdf_engine.dart";
import "../engines/vision_chat_pipeline.dart";
import "../models/document_pipeline_models.dart";
import "../models/openai_vision_models.dart";
import "../models/request_log_entry.dart";
import "../models/telemetry_snapshot.dart";
import "../services/pairing_token_service.dart";
import "routes/barcode_routes.dart";
import "routes/document_routes.dart";
import "routes/health_routes.dart";
import "routes/ocr_routes.dart";
import "routes/openai_routes.dart";
import "routes/status_routes.dart";
import "routes/web_ui_routes.dart";

/// Embedded HTTP server built on `shelf` and `shelf_router`.
///
/// Kept independent of the UI and BLoC layers; publishes a [RequestLogEntry]
/// to [requestLogs] for each handled request.
class EdgeHttpServer {
  EdgeHttpServer({
    FutureOr<TelemetrySnapshot> Function()? telemetryProvider,
    OcrEngine? ocrEngine,
    BarcodeEngine? barcodeEngine,
    FaceDetectionEngine? faceDetectionEngine,
    PdfRasterizer? pdfRasterizer,
    SearchablePdfEngine? searchablePdfEngine,
    PiiRedactionEngine? piiRedactionEngine,
    EntityExtractionEngine? entityExtractionEngine,
    LiteRtLmEngine? liteRtLmEngine,
    LocalGenAiEngine? localGenAiEngine,
    VisionChatPipeline? visionChatPipeline,
    this.webAssetLoader,
    this.hostname = "android-edge.local",
    String? authToken,
  }) : _telemetryProvider =
           telemetryProvider ??
           (() => TelemetrySnapshot(timestamp: DateTime.now().toUtc())),
       _authToken = (authToken != null && authToken.trim().isNotEmpty)
           ? authToken.trim()
           : PairingTokenService.generateToken(),
       _ocrEngine = ocrEngine ?? MlKitOcrEngine(),
       _barcodeEngine = barcodeEngine ?? MlKitBarcodeEngine(),
       _faceDetectionEngine = faceDetectionEngine ?? MlKitFaceDetectionEngine(),
       _pdfRasterizer = pdfRasterizer ?? PdfxDocumentRasterizer(),
       _entityExtractionEngine =
           entityExtractionEngine ?? HybridEntityExtractionEngine(),
       _liteRtLmEngine = liteRtLmEngine ?? MethodChannelLiteRtLmEngine() {
    _searchablePdfEngine =
        searchablePdfEngine ??
        SearchablePdfEngine(
          ocrEngine: _ocrEngine,
          pdfRasterizer: _pdfRasterizer,
        );
    _piiRedactionEngine =
        piiRedactionEngine ??
        PiiRedactionEngine(
          ocrEngine: _ocrEngine,
          faceDetectionEngine: _faceDetectionEngine,
          pdfRasterizer: _pdfRasterizer,
          entityExtractionEngine: _entityExtractionEngine,
        );
    _localGenAiEngine =
        localGenAiEngine ??
        ThreeTierGenAiRuntime(
          entityExtractionEngine: _entityExtractionEngine,
          liteRtLmEngine: _liteRtLmEngine,
          tier3Runner: _liteRtLmEngine.runInference,
          inferenceTimeout: const Duration(seconds: 30),
        );
    _visionChatPipeline =
        visionChatPipeline ??
        VisionChatPipeline(
          ocrEngine: _ocrEngine,
          pdfRasterizer: _pdfRasterizer,
          entityExtractionEngine: _entityExtractionEngine,
          localGenAiEngine: _localGenAiEngine,
        );
  }

  final FutureOr<TelemetrySnapshot> Function() _telemetryProvider;
  final OcrEngine _ocrEngine;
  final BarcodeEngine _barcodeEngine;
  final FaceDetectionEngine _faceDetectionEngine;
  final PdfRasterizer _pdfRasterizer;
  late final SearchablePdfEngine _searchablePdfEngine;
  late final PiiRedactionEngine _piiRedactionEngine;
  final EntityExtractionEngine _entityExtractionEngine;
  final LiteRtLmEngine _liteRtLmEngine;
  late final LocalGenAiEngine _localGenAiEngine;
  late final VisionChatPipeline _visionChatPipeline;
  final WebAssetLoader? webAssetLoader;
  final String hostname;

  final List<HttpServer> _servers = <HttpServer>[];
  final AuthRateLimiter _rateLimiter = AuthRateLimiter();
  String _authToken;
  bool _tlsEnabled = false;
  Set<String> _allowedAuthorities = const <String>{};
  Set<String> _allowedOrigins = const <String>{};
  DateTime? _startedAt;
  int _requestCounter = 0;

  final StreamController<RequestLogEntry> _logController =
      StreamController<RequestLogEntry>.broadcast();
  final StreamController<DocumentJobRecord> _documentJobController =
      StreamController<DocumentJobRecord>.broadcast();
  final StreamController<OpenAiJobRecord> _openAiJobController =
      StreamController<OpenAiJobRecord>.broadcast();

  Stream<RequestLogEntry> get requestLogs => _logController.stream;
  Stream<DocumentJobRecord> get documentJobs => _documentJobController.stream;
  Stream<OpenAiJobRecord> get openAiJobs => _openAiJobController.stream;
  LocalGenAiEngine get localGenAiEngine => _localGenAiEngine;

  String get authToken => _authToken;
  bool get isRunning => _servers.isNotEmpty;
  bool get isTlsEnabled => _tlsEnabled;
  int? get boundPort => _servers.isEmpty ? null : _servers.first.port;
  List<String> get boundAddresses =>
      _servers.map((s) => s.address.address).toList(growable: false);
  DateTime? get startedAt => _startedAt;

  /// Updates the active Bearer pairing token without restarting bound sockets.
  void updateAuthToken(String token) {
    final trimmed = token.trim();
    if (trimmed.isNotEmpty) {
      _authToken = trimmed;
    }
  }

  int get uptimeSeconds {
    final started = _startedAt;
    if (started == null) return 0;
    return DateTime.now().difference(started).inSeconds;
  }

  /// Begins listening on [bindAddress] (and optionally loopback `127.0.0.1`)
  /// on [port], enforcing Host/Origin checks and Bearer token authentication.
  Future<int> start({
    int port = 8080,
    String bindAddress = "127.0.0.1",
    bool bindLoopback = true,
    SecurityContext? securityContext,
    String? authToken,
    Set<String>? allowedHosts,
    Set<String>? allowedOrigins,
  }) async {
    if (_servers.isNotEmpty) {
      return _servers.first.port;
    }

    if (authToken != null && authToken.trim().isNotEmpty) {
      _authToken = authToken.trim();
    }

    final parsedBind = InternetAddress.tryParse(bindAddress.trim());
    final primaryAddr =
        (parsedBind == null ||
            parsedBind.type != InternetAddressType.IPv4 ||
            parsedBind.address == "0.0.0.0")
        ? InternetAddress.loopbackIPv4
        : parsedBind;

    _tlsEnabled = securityContext != null;
    _allowedOrigins = {
      for (final origin in allowedOrigins ?? const <String>{})
        if (origin.trim().isNotEmpty) origin.trim().toLowerCase(),
    };

    final hostSet = <String>{
      primaryAddr.address,
      if (bindLoopback) "127.0.0.1",
      "localhost",
      hostname.trim().toLowerCase(),
      for (final host in allowedHosts ?? const <String>{})
        if (host.trim().isNotEmpty) host.trim().toLowerCase(),
    };

    Set<String> buildAuthorities(int actualPort) {
      final defaultPort = _tlsEnabled ? 443 : 80;
      final authorities = <String>{};
      for (final host in hostSet) {
        authorities.add("$host:$actualPort");
        if (actualPort == defaultPort) {
          authorities.add(host);
        }
      }
      return authorities;
    }

    if (port > 0) {
      _allowedAuthorities = buildAuthorities(port);
    }

    final rootRouter = Router();
    final healthRoutes = HealthRoutes(
      uptimeSecondsProvider: () => uptimeSeconds,
    );
    final statusRoutes = StatusRoutes(
      uptimeSecondsProvider: () => uptimeSeconds,
      boundPortProvider: () => boundPort,
      telemetryProvider: _telemetryProvider,
      hostname: hostname,
    );
    final ocrRoutes = OcrRoutes(ocrEngine: _ocrEngine);
    final barcodeRoutes = BarcodeRoutes(barcodeEngine: _barcodeEngine);
    final documentRoutes = DocumentRoutes(
      searchablePdfEngine: _searchablePdfEngine,
      piiRedactionEngine: _piiRedactionEngine,
      onJobCompleted: (job) {
        if (!_documentJobController.isClosed) {
          _documentJobController.add(job);
        }
      },
    );
    final openAiRoutes = OpenAiRoutes(
      visionChatPipeline: _visionChatPipeline,
      localGenAiEngine: _localGenAiEngine,
      onJobCompleted: (job) {
        if (!_openAiJobController.isClosed) {
          _openAiJobController.add(job);
        }
      },
    );
    final webUiRoutes = WebUiRoutes(assetLoader: webAssetLoader);
    rootRouter.mount("/", healthRoutes.router.call);
    rootRouter.mount("/", statusRoutes.router.call);
    rootRouter.mount("/", ocrRoutes.router.call);
    rootRouter.mount("/", barcodeRoutes.router.call);
    rootRouter.mount("/", documentRoutes.router.call);
    rootRouter.mount("/", openAiRoutes.router.call);
    rootRouter.mount("/", webUiRoutes.router.call);

    final handler = const Pipeline()
        .addMiddleware(_requestLoggingMiddleware())
        .addMiddleware(_securityHeadersMiddleware())
        .addMiddleware(_hostAndOriginMiddleware())
        .addMiddleware(_authenticationMiddleware())
        .addHandler((Request request) async {
          final response = await rootRouter.call(request);
          if (response.statusCode == 404 &&
              response.headers["content-type"] == null) {
            return Response.notFound(
              jsonEncode({
                "error": "not_found",
                "path": "/${request.url.path}",
              }),
              headers: const {
                "content-type": "application/json; charset=utf-8",
              },
            );
          }
          return response;
        });

    _startedAt = DateTime.now();
    try {
      final primaryServer = await shelf_io.serve(
        handler,
        primaryAddr,
        port,
        securityContext: securityContext,
        shared: true,
      );
      _servers.add(primaryServer);
      final actualPort = primaryServer.port;
      _allowedAuthorities = buildAuthorities(actualPort);

      if (bindLoopback && !primaryAddr.isLoopback) {
        try {
          final loopbackServer = await shelf_io.serve(
            handler,
            InternetAddress.loopbackIPv4,
            actualPort,
            securityContext: securityContext,
            shared: true,
          );
          _servers.add(loopbackServer);
        } on SocketException catch (error) {
          final code = error.osError?.errorCode;
          final msg = error.message.toLowerCase();
          final alreadyInUse =
              code == 98 ||
              code == 48 ||
              msg.contains("address already in use");
          if (!alreadyInUse) {
            rethrow;
          }
        }
      }

      return actualPort;
    } catch (_) {
      for (final server in _servers) {
        await server.close(force: true);
      }
      _servers.clear();
      _startedAt = null;
      _tlsEnabled = false;
      rethrow;
    }
  }

  /// Shuts down all bound HTTP/HTTPS server sockets.
  Future<void> stop() async {
    final active = List<HttpServer>.from(_servers);
    _servers.clear();
    _startedAt = null;
    _tlsEnabled = false;
    for (final server in active) {
      await server.close(force: true);
    }
  }

  Future<void> dispose() async {
    await stop();
    await _ocrEngine.dispose();
    await _barcodeEngine.dispose();
    await _faceDetectionEngine.dispose();
    await _pdfRasterizer.dispose();
    await _entityExtractionEngine.dispose();
    await _localGenAiEngine.dispose();
    await _liteRtLmEngine.dispose();
    await _logController.close();
    await _documentJobController.close();
    await _openAiJobController.close();
  }

  static const Map<String, String> _securityHeaders = {
    "x-content-type-options": "nosniff",
    "x-frame-options": "DENY",
    "referrer-policy": "no-referrer",
    "content-security-policy": "default-src 'self'; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'",
  };

  Middleware _securityHeadersMiddleware() {
    return (Handler innerHandler) {
      return (Request request) async {
        final response = await innerHandler(request);
        return response.change(headers: _securityHeaders);
      };
    };
  }

  Middleware _hostAndOriginMiddleware() {
    return (Handler innerHandler) {
      return (Request request) async {
        final rawHost = request.headers["host"]?.trim().toLowerCase();
        if (rawHost == null ||
            rawHost.isEmpty ||
            !_allowedAuthorities.contains(rawHost)) {
          return _jsonError(
            HttpStatus.forbidden,
            "forbidden_host",
            "Host header is not permitted by this server.",
          );
        }

        if (request.method.toUpperCase() == "OPTIONS") {
          return _jsonError(
            HttpStatus.forbidden,
            "cors_not_allowed",
            "Cross-origin preflight requests are not permitted.",
          );
        }

        final rawOrigin = request.headers["origin"]?.trim();
        if (rawOrigin != null && rawOrigin.isNotEmpty) {
          if (!_isAllowedOrigin(rawOrigin)) {
            return _jsonError(
              HttpStatus.forbidden,
              "forbidden_origin",
              "Cross-origin requests are not permitted.",
            );
          }
        }

        return innerHandler(request);
      };
    };
  }

  bool _isAllowedOrigin(String rawOrigin) {
    final lower = rawOrigin.toLowerCase();
    if (lower == "null") {
      return false;
    }
    if (_allowedOrigins.contains(lower)) {
      return true;
    }
    final uri = Uri.tryParse(rawOrigin);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return false;
    }
    final expectedScheme = _tlsEnabled ? "https" : "http";
    if (uri.scheme.toLowerCase() != expectedScheme) {
      return false;
    }
    final defaultPort = expectedScheme == "https" ? 443 : 80;
    final port = uri.hasPort ? uri.port : defaultPort;
    final authority = "${uri.host.toLowerCase()}:$port";
    return _allowedAuthorities.contains(authority);
  }

  Middleware _authenticationMiddleware() {
    return (Handler innerHandler) {
      return (Request request) async {
        final path = request.url.path;
        final method = request.method.toUpperCase();
        final isApiRoute = path == "v1" || path.startsWith("v1/");
        if (!isApiRoute && (method == "GET" || method == "HEAD")) {
          return innerHandler(request);
        }

        final connectionInfo =
            request.context["shelf.io.connection_info"] as HttpConnectionInfo?;
        final remoteIp = connectionInfo?.remoteAddress.address ?? "unknown";

        if (_rateLimiter.isBlocked(remoteIp)) {
          return Response(
            429,
            body: jsonEncode({
              "error": "too_many_requests",
              "message": "Too many failed authentication attempts.",
            }),
            headers: {
              "content-type": "application/json; charset=utf-8",
              "retry-after": "${_rateLimiter.retryAfterSeconds(remoteIp)}",
            },
          );
        }

        final authHeader = request.headers["authorization"]?.trim() ?? "";
        String? candidate;
        if (authHeader.length > 7 &&
            authHeader.substring(0, 7).toLowerCase() == "bearer ") {
          candidate = authHeader.substring(7).trim();
        }

        if (candidate == null ||
            !PairingTokenService.verifyToken(candidate, _authToken)) {
          _rateLimiter.recordFailure(remoteIp);
          return Response(
            HttpStatus.unauthorized,
            body: jsonEncode({
              "error": "unauthorized",
              "message": "Valid Bearer pairing token required.",
            }),
            headers: const {
              "content-type": "application/json; charset=utf-8",
              "www-authenticate": "Bearer realm=\"Droid Edge Server\"",
            },
          );
        }

        _rateLimiter.reset(remoteIp);
        return innerHandler(request);
      };
    };
  }

  static Response _jsonError(int statusCode, String error, String message) {
    return Response(
      statusCode,
      body: jsonEncode({"error": error, "message": message}),
      headers: const {"content-type": "application/json; charset=utf-8"},
    );
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
        final normalizedPath = request.requestedUri.path.isEmpty
            ? "/"
            : request.requestedUri.path;

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
