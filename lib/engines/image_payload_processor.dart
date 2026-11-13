import "dart:convert";
import "dart:io";
import "dart:isolate";
import "dart:math";
import "dart:typed_data";

import "package:image/image.dart" as img;
import "package:mime/mime.dart";

class ImagePayloadException implements Exception {
  const ImagePayloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Metadata
class PreparedImagePayload {
  const PreparedImagePayload({
    required this.filePath,
    required this.mimeType,
    required this.byteLength,
    this.width,
    this.height,
  });

  final String filePath;
  final String mimeType;
  final int byteLength;
  final int? width;
  final int? height;

  Future<void> cleanup() async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
    }
  }
}
class ImagePayloadProcessor {
  const ImagePayloadProcessor._();

  static final Random _random = Random();

  /// Validates raw image [bytes], extracts dimensions, and stages a temporary
  /// file in a background isolate.
  static Future<PreparedImagePayload> prepareFromBytes(Uint8List bytes) {
    final uniqueSuffix = _random.nextInt(1 << 30);
    return Isolate.run(() => _processBytesInIsolate(bytes, uniqueSuffix));
  }

  /// Decodes a raw base64 string or `data:image/...;base64,...` URI, validates
  /// the resulting image bytes, and stages a temporary file in a background
  /// isolate.
  static Future<PreparedImagePayload> prepareFromBase64(
    String base64OrDataUri,
  ) {
    final uniqueSuffix = _random.nextInt(1 << 30);
    return Isolate.run(() {
      final trimmed = base64OrDataUri.trim();
      if (trimmed.isEmpty) {
        throw const ImagePayloadException("Base64 image payload is empty.");
      }

      var encoded = trimmed;
      if (trimmed.startsWith("data:")) {
        final commaIndex = trimmed.indexOf(",");
        if (commaIndex == -1 || commaIndex == trimmed.length - 1) {
          throw const ImagePayloadException(
            "Malformed data URI for base64 image.",
          );
        }
        encoded = trimmed.substring(commaIndex + 1);
      }

      final Uint8List bytes;
      try {
        bytes = base64Decode(encoded.replaceAll(RegExp(r"\s+"), ""));
      } on FormatException {
        throw const ImagePayloadException(
          "Invalid base64 encoding in image payload.",
        );
      }

      return _processBytesInIsolate(bytes, uniqueSuffix);
    });
  }

  static PreparedImagePayload _processBytesInIsolate(
    Uint8List bytes,
    int uniqueSuffix,
  ) {
    if (bytes.isEmpty) {
      throw const ImagePayloadException("Image payload is empty.");
    }

    final headerLen = bytes.length < 32 ? bytes.length : 32;
    final detectedMime = lookupMimeType(
      "",
      headerBytes: bytes.sublist(0, headerLen),
    );
    final decoder = img.findDecoderForData(bytes);

    final isSupportedImageMime =
        detectedMime != null && detectedMime.startsWith("image/");
    if (!isSupportedImageMime && decoder == null) {
      throw const ImagePayloadException(
        "Unsupported or corrupted image payload.",
      );
    }

    final resolvedMime = detectedMime ?? _mimeFromFormat(decoder?.format);

    int? width;
    int? height;
    var outputBytes = bytes;
    var outputMime = resolvedMime;

    if (decoder != null) {
      final info = decoder.startDecode(bytes);
      if (info != null) {
        width = info.width;
        height = info.height;
      }

      // Flatten transparent/RGBA images (such as PNG barcodes or QR codes with
      // transparent `(0,0,0,0)` backgrounds) onto a solid white canvas so
      // Android BitmapFactory / ML Kit YUV luminance conversion does not turn
      // transparent backgrounds into solid black.
      if (resolvedMime != "image/jpeg") {
        final decoded = decoder.decode(bytes);
        if (decoded != null) {
          width = decoded.width;
          height = decoded.height;
          if (decoded.hasAlpha && _hasTransparentPixels(decoded)) {
            final flattened = _flattenAlphaOntoWhite(decoded);
            outputBytes = Uint8List.fromList(img.encodePng(flattened));
            outputMime = "image/png";
          }
        }
      } else if (width == null || height == null) {
        final decoded = decoder.decode(bytes);
        if (decoded != null) {
          width = decoded.width;
          height = decoded.height;
        }
      }
    }

    final extension = _extensionForMime(outputMime);
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    final sep = Platform.pathSeparator;
    final tempDir = Directory.systemTemp.path;
    final filePath =
        "$tempDir${sep}droid_edge_img_${timestamp}_$uniqueSuffix.$extension";
    File(filePath).writeAsBytesSync(outputBytes, flush: true);

    return PreparedImagePayload(
      filePath: filePath,
      mimeType: outputMime,
      byteLength: outputBytes.length,
      width: width,
      height: height,
    );
  }

  static bool _hasTransparentPixels(img.Image image) {
    final maxAlpha = image.maxChannelValue;
    for (final pixel in image) {
      if (pixel.a < maxAlpha) {
        return true;
      }
    }
    return false;
  }

  static img.Image _flattenAlphaOntoWhite(img.Image source) {
    final out = img.Image(
      width: source.width,
      height: source.height,
      numChannels: 3,
    );
    final maxVal = source.maxChannelValue;
    for (var y = 0; y < source.height; y++) {
      for (var x = 0; x < source.width; x++) {
        final p = source.getPixel(x, y);
        final alpha = (p.a / maxVal).clamp(0.0, 1.0);
        final invAlpha = 1.0 - alpha;
        final r = (p.rNormalized * 255.0 * alpha + 255.0 * invAlpha).round();
        final g = (p.gNormalized * 255.0 * alpha + 255.0 * invAlpha).round();
        final b = (p.bNormalized * 255.0 * alpha + 255.0 * invAlpha).round();
        out.setPixelRgb(
          x,
          y,
          r.clamp(0, 255),
          g.clamp(0, 255),
          b.clamp(0, 255),
        );
      }
    }
    return out;
  }

  static String _mimeFromFormat(img.ImageFormat? format) {
    switch (format) {
      case img.ImageFormat.jpg:
        return "image/jpeg";
      case img.ImageFormat.png:
        return "image/png";
      case img.ImageFormat.webp:
        return "image/webp";
      case img.ImageFormat.gif:
        return "image/gif";
      case img.ImageFormat.bmp:
        return "image/bmp";
      case img.ImageFormat.tiff:
        return "image/tiff";
      default:
        return "application/octet-stream";
    }
  }

  static String _extensionForMime(String mimeType) {
    switch (mimeType) {
      case "image/jpeg":
        return "jpg";
      case "image/png":
        return "png";
      case "image/webp":
        return "webp";
      case "image/gif":
        return "gif";
      case "image/bmp":
        return "bmp";
      case "image/tiff":
        return "tiff";
      default:
        return "img";
    }
  }
}
