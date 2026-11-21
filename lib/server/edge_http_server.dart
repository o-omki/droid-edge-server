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
  })  : _telemetryProvider = telemetryProvider ??
            (() => TelemetrySnapshot(timestamp: DateTime.now().toUtc())),
        _ocrEngine = ocrEngine ?? MlKitOcrEngine(),
        _barcodeEngine = barcodeEngine ?? MlKitBarcodeEngine(),
        _faceDetectionEngine =
            faceDetectionEngine ?? MlKitFaceDetectionEngine(),
        _pdfRasterizer = pdfRasterizer ?? PdfxDocumentRasterizer(),
        _entityExtractionEngine =
            entityExtractionEngine ?? HybridEntityExtractionEngine(),
        _liteRtLmEngine = liteRtLmEngine ?? MethodChannelLiteRtLmEngine() {
    _searchablePdfEngine = searchablePdfEngine ??
        SearchablePdfEngine(
          ocrEngine: _ocrEngine,
          pdfRasterizer: _pdfRasterizer,
        );
    _piiRedactionEngine = piiRedactionEngine ??
        PiiRedactionEngine(
          ocrEngine: _ocrEngine,
          faceDetectionEngine: _faceDetectionEngine,
          pdfRasterizer: _pdfRasterizer,
          entityExtractionEngine: _entityExtractionEngine,
        );
    _localGenAiEngine = localGenAiEngine ??
        ThreeTierGenAiRuntime(
          entityExtractionEngine: _entityExtractionEngine,
          liteRtLmEngine: _liteRtLmEngine,
          tier3Runner: _liteRtLmEngine.runInference,
          inferenceTimeout: const Duration(seconds: 30),
        );
    _visionChatPipeline = visionChatPipeline ??
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

  HttpServer? _server;
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
        .addMiddleware(_corsMiddleware())
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

  static const Map<String, String> _corsHeaders = {
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "GET, POST, OPTIONS",
    "access-control-allow-headers":
        "Content-Type, Authorization, X-Requested-With",
  };

  Middleware _corsMiddleware() {
    return (Handler innerHandler) {
      return (Request request) async {
        if (request.method == "OPTIONS") {
          return Response.ok("", headers: _corsHeaders);
        }
        final response = await innerHandler(request);
        return response.change(headers: _corsHeaders);
      };
    };
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

