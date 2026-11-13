import "dart:convert";
import "dart:typed_data";

import "package:shelf/shelf.dart";
import "package:shelf_multipart/shelf_multipart.dart";

import "../../engines/image_payload_processor.dart";

class ParsedImageRequest {
  const ParsedImageRequest({
    required this.payload,
    this.script,
  });

  final PreparedImagePayload payload;
  final String? script;
}

/// Extracts image payloads from `multipart/form-data`, `application/json`
/// (base64 / data URI), or raw binary request bodies.
class ImageRequestParser {
  const ImageRequestParser._();

  /// Parses [request] and returns a staged [PreparedImagePayload] along with
  /// any optional `script` parameter supplied in the query string, form, or
  /// JSON body.
  static Future<ParsedImageRequest> parse(Request request) async {
    final queryScript = request.url.queryParameters["script"];

    final formRequest = request.formData();
    if (formRequest != null) {
      return _parseMultipartFormData(formRequest, queryScript: queryScript);
    }

    final contentType =
        (request.headers["content-type"] ?? "").toLowerCase();

    if (contentType.contains("application/json")) {
      final rawText = await request.readAsString();
      return _parseJsonPayload(rawText, queryScript: queryScript);
    }

    final rawBytes = await _readAllBytes(request);
    if (rawBytes.isEmpty) {
      throw const ImagePayloadException(
        "Request body is empty. Send multipart form-data (field \"image\"), "
        "JSON {\"image\": \"<base64>\"}, or raw image bytes.",
      );
    }

    // If the caller omitted Content-Type on a JSON payload, detect leading "{".
    if (contentType.isEmpty && _looksLikeJsonObject(rawBytes)) {
      final decodedText = utf8.decode(rawBytes, allowMalformed: false);
      return _parseJsonPayload(decodedText, queryScript: queryScript);
    }

    final payload = await ImagePayloadProcessor.prepareFromBytes(rawBytes);
    return ParsedImageRequest(payload: payload, script: queryScript);
  }

  static Future<ParsedImageRequest> _parseMultipartFormData(
    FormDataRequest formRequest, {
    String? queryScript,
  }) async {
    Uint8List? imageBytes;
    Uint8List? fallbackFileBytes;
    String? formScript;

    await for (final field in formRequest.formData) {
      final name = field.name.toLowerCase();
      if (name == "script") {
        formScript = (await field.part.readString()).trim();
      } else if (name == "image" || name == "file") {
        imageBytes ??= await field.part.readBytes();
      } else if (fallbackFileBytes == null &&
          (field.filename != null ||
              (field.part.headers["content-type"] ?? "")
                  .toLowerCase()
                  .startsWith("image/"))) {
        fallbackFileBytes = await field.part.readBytes();
      } else {
        // Drain unused parts to avoid leaving the underlying stream unconsumed.
        await field.part.drain<void>();
      }
    }

    final selectedBytes = imageBytes ?? fallbackFileBytes;
    if (selectedBytes == null || selectedBytes.isEmpty) {
      throw const ImagePayloadException(
        "No image file found in multipart request. Expected field \"image\" "
        "or \"file\".",
      );
    }

    final payload = await ImagePayloadProcessor.prepareFromBytes(selectedBytes);
    final effectiveScript =
        (formScript != null && formScript.isNotEmpty) ? formScript : queryScript;
    return ParsedImageRequest(payload: payload, script: effectiveScript);
  }

  static Future<ParsedImageRequest> _parseJsonPayload(
    String rawText, {
    String? queryScript,
  }) async {
    if (rawText.trim().isEmpty) {
      throw const ImagePayloadException("JSON request body is empty.");
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(rawText);
    } on FormatException {
      throw const ImagePayloadException("Malformed JSON request body.");
    }

    if (decoded is! Map<String, dynamic>) {
      throw const ImagePayloadException(
        "JSON body must be an object containing an \"image\" base64 string.",
      );
    }

    final imageValue =
        decoded["image"] ?? decoded["image_base64"] ?? decoded["data"];
    if (imageValue is! String || imageValue.trim().isEmpty) {
      throw const ImagePayloadException(
        "JSON object must include a non-empty \"image\" base64 string.",
      );
    }

    final jsonScript = decoded["script"];
    final effectiveScript =
        (jsonScript is String && jsonScript.trim().isNotEmpty)
            ? jsonScript.trim()
            : queryScript;

    final payload = await ImagePayloadProcessor.prepareFromBase64(imageValue);
    return ParsedImageRequest(payload: payload, script: effectiveScript);
  }

  static Future<Uint8List> _readAllBytes(Request request) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request.read()) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  static bool _looksLikeJsonObject(Uint8List bytes) {
    for (final byte in bytes) {
      // Skip ASCII whitespace: space, tab, LF, CR.
      if (byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D) {
        continue;
      }
      return byte == 0x7B; // "{"
    }
    return false;
  }
}

