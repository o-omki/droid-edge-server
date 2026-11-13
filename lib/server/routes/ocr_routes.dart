import "dart:convert";

import "package:shelf/shelf.dart";
import "package:shelf_router/shelf_router.dart";

import "../../engines/image_payload_processor.dart";
import "../../engines/ocr_engine.dart";
import "../../models/ocr_result.dart";
import "image_request_parser.dart";

/// HTTP route handler for `POST /v1/ocr`.
class OcrRoutes {
  OcrRoutes({required this.ocrEngine});

  final OcrEngine ocrEngine;

  Router get router {
    final router = Router();
    router.post("/v1/ocr", _handleOcr);
    return router;
  }

  Future<Response> _handleOcr(Request request) async {
    ParsedImageRequest? parsed;
    try {
      parsed = await ImageRequestParser.parse(request);
      final script = OcrScript.fromName(parsed.script);
      final result = await ocrEngine.processImage(
        parsed.payload,
        script: script,
      );
      return Response.ok(
        jsonEncode(result.toJson()),
        headers: const {"content-type": "application/json; charset=utf-8"},
      );
    } on ImagePayloadException catch (error) {
      return Response.badRequest(
        body: jsonEncode({
          "error": "bad_request",
          "message": error.message,
        }),
        headers: const {"content-type": "application/json; charset=utf-8"},
      );
    } on FormatException catch (error) {
      return Response.badRequest(
        body: jsonEncode({
          "error": "bad_request",
          "message": error.message,
        }),
        headers: const {"content-type": "application/json; charset=utf-8"},
      );
    } finally {
      await parsed?.payload.cleanup();
    }
  }
}

