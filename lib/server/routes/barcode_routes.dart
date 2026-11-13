import "dart:convert";

import "package:shelf/shelf.dart";
import "package:shelf_router/shelf_router.dart";

import "../../engines/barcode_engine.dart";
import "../../engines/image_payload_processor.dart";
import "image_request_parser.dart";

/// HTTP route handler for `POST /v1/barcode`.
class BarcodeRoutes {
  BarcodeRoutes({required this.barcodeEngine});

  final BarcodeEngine barcodeEngine;

  Router get router {
    final router = Router();
    router.post("/v1/barcode", _handleBarcode);
    return router;
  }

  Future<Response> _handleBarcode(Request request) async {
    ParsedImageRequest? parsed;
    try {
      parsed = await ImageRequestParser.parse(request);
      final result = await barcodeEngine.processImage(parsed.payload);
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
    } finally {
      await parsed?.payload.cleanup();
    }
  }
}

