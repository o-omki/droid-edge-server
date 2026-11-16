import "package:flutter/foundation.dart";
import "package:flutter/services.dart";
import "package:mime/mime.dart";
import "package:shelf/shelf.dart";
import "package:shelf_router/shelf_router.dart";

/// Callback used to load bundled web asset bytes by Flutter asset key.
typedef WebAssetLoader = Future<Uint8List?> Function(String assetKey);

/// HTTP route handler for serving the offline single-page web interface from
/// Flutter's bundled `assets/web/` directory.
class WebUiRoutes {
  WebUiRoutes({
    WebAssetLoader? assetLoader,
    this.assetPrefix = "assets/web",
  }) : _assetLoader = assetLoader ?? _defaultRootBundleLoader;

  final WebAssetLoader _assetLoader;
  final String assetPrefix;

  Router get router {
    final router = Router();
    router.get("/", (Request request) => _serveAsset("index.html"));
    router.get("/<assetPath|.*>", _handleAssetRequest);
    return router;
  }

  Future<Response> _handleAssetRequest(Request request, String assetPath) async {
    final sanitized = _sanitizeRelativePath(assetPath);
    if (sanitized == null) {
      // Leave content-type unset so EdgeHttpServer emits its standard JSON 404.
      return Response.notFound("");
    }
    return _serveAsset(sanitized);
  }

  Future<Response> _serveAsset(String relativePath) async {
    final assetKey = "$assetPrefix/$relativePath";
    final bytes = await _assetLoader(assetKey);
    if (bytes == null) {
      return Response.notFound("");
    }

    final mimeType = lookupMimeType(assetKey) ?? "application/octet-stream";
    final isTextLike = mimeType.startsWith("text/") ||
        mimeType == "application/javascript" ||
        mimeType == "application/json";
    final contentType = isTextLike ? "$mimeType; charset=utf-8" : mimeType;

    return Response.ok(
      bytes,
      headers: {
        "content-type": contentType,
        "cache-control": "no-cache",
      },
    );
  }

  /// Validates and normalises a relative asset path, returning `null` if it
  /// attempts directory traversal or targets an API namespace.
  String? _sanitizeRelativePath(String rawPath) {
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty) {
      return "index.html";
    }
    if (trimmed.contains("\\") || trimmed.contains("\x00")) {
      return null;
    }

    final segments = trimmed.split("/").where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) {
      return "index.html";
    }
    for (final segment in segments) {
      if (segment == "." || segment == "..") {
        return null;
      }
    }
    if (segments.first == "v1") {
      return null;
    }

    return segments.join("/");
  }

  static Future<Uint8List?> _defaultRootBundleLoader(String assetKey) async {
    try {
      final data = await rootBundle.load(assetKey);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } on FlutterError {
      return null;
    } catch (_) {
      return null;
    }
  }
}

