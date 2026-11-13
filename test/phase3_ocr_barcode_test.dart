import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:droid_edge_server/engines/barcode_engine.dart";
import "package:droid_edge_server/engines/image_payload_processor.dart";
import "package:droid_edge_server/engines/ocr_engine.dart";
import "package:droid_edge_server/models/barcode_result.dart";
import "package:droid_edge_server/models/geometry_models.dart";
import "package:droid_edge_server/models/ocr_result.dart";
import "package:droid_edge_server/server/edge_http_server.dart";
import "package:flutter_test/flutter_test.dart";
import "package:image/image.dart" as img;

class _FakeOcrEngine implements OcrEngine {
  String? lastTempFilePath;
  bool fileExistedDuringInference = false;
  OcrScript? lastScript;
  int? lastImageWidth;
  int? lastImageHeight;
  bool disposed = false;

  @override
  Future<OcrResult> processImage(
    PreparedImagePayload payload, {
    OcrScript script = OcrScript.latin,
  }) async {
    lastTempFilePath = payload.filePath;
    fileExistedDuringInference = await File(payload.filePath).exists();
    lastScript = script;
    lastImageWidth = payload.width;
    lastImageHeight = payload.height;

    return OcrResult(
      text: "TOTAL 42.50",
      script: script.name,
      detectedLanguages: const ["en"],
      inferenceMs: 12,
      imageWidth: payload.width,
      imageHeight: payload.height,
      blocks: const [
        OcrTextBlock(
          text: "TOTAL 42.50",
          boundingBox: BoundingBoxRect(
            left: 10,
            top: 12,
            right: 110,
            bottom: 34,
          ),
          cornerPoints: [
            CornerPoint(x: 10, y: 12),
            CornerPoint(x: 110, y: 12),
            CornerPoint(x: 110, y: 34),
            CornerPoint(x: 10, y: 34),
          ],
          recognizedLanguages: ["en"],
          lines: [
            OcrTextLine(
              text: "TOTAL 42.50",
              boundingBox: BoundingBoxRect(
                left: 10,
                top: 12,
                right: 110,
                bottom: 34,
              ),
              cornerPoints: [
                CornerPoint(x: 10, y: 12),
                CornerPoint(x: 110, y: 12),
                CornerPoint(x: 110, y: 34),
                CornerPoint(x: 10, y: 34),
              ],
              recognizedLanguages: ["en"],
              confidence: 0.98,
              elements: [
                OcrTextElement(
                  text: "TOTAL",
                  boundingBox: BoundingBoxRect(
                    left: 10,
                    top: 12,
                    right: 58,
                    bottom: 34,
                  ),
                  recognizedLanguages: ["en"],
                  confidence: 0.99,
                ),
                OcrTextElement(
                  text: "42.50",
                  boundingBox: BoundingBoxRect(
                    left: 64,
                    top: 12,
                    right: 110,
                    bottom: 34,
                  ),
                  recognizedLanguages: ["en"],
                  confidence: 0.97,
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class _FakeBarcodeEngine implements BarcodeEngine {
  String? lastTempFilePath;
  bool fileExistedDuringInference = false;
  int? lastImageWidth;
  int? lastImageHeight;
  bool disposed = false;

  @override
  Future<BarcodeResult> processImage(PreparedImagePayload payload) async {
    lastTempFilePath = payload.filePath;
    fileExistedDuringInference = await File(payload.filePath).exists();
    lastImageWidth = payload.width;
    lastImageHeight = payload.height;

    return BarcodeResult(
      inferenceMs: 5,
      imageWidth: payload.width,
      imageHeight: payload.height,
      barcodes: const [
        DetectedBarcodeItem(
          rawValue: "http://android-edge.local:8080",
          displayValue: "http://android-edge.local:8080",
          format: "qrCode",
          valueType: "url",
          boundingBox: BoundingBoxRect(
            left: 5,
            top: 5,
            right: 55,
            bottom: 55,
          ),
          cornerPoints: [
            CornerPoint(x: 5, y: 5),
            CornerPoint(x: 55, y: 5),
            CornerPoint(x: 55, y: 55),
            CornerPoint(x: 5, y: 55),
          ],
        ),
      ],
    );
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

Uint8List _createSamplePng({int width = 120, int height = 60}) {
  final image = img.Image(width: width, height: height);
  return Uint8List.fromList(img.encodePng(image));
}

List<int> _buildMultipartBody({
  required String boundary,
  required String fieldName,
  required String filename,
  required String fileContentType,
  required Uint8List fileBytes,
  Map<String, String> textFields = const {},
}) {
  final builder = BytesBuilder();
  for (final entry in textFields.entries) {
    builder.add(
      utf8.encode(
        "--$boundary\r\n"
        "Content-Disposition: form-data; name=\"${entry.key}\"\r\n\r\n"
        "${entry.value}\r\n",
      ),
    );
  }
  builder.add(
    utf8.encode(
      "--$boundary\r\n"
      "Content-Disposition: form-data; name=\"$fieldName\"; "
      "filename=\"$filename\"\r\n"
      "Content-Type: $fileContentType\r\n\r\n",
    ),
  );
  builder.add(fileBytes);
  builder.add(utf8.encode("\r\n--$boundary--\r\n"));
  return builder.takeBytes();
}

void main() {
  group("Phase 3 OCR & Barcode Endpoints", () {
    late _FakeOcrEngine fakeOcr;
    late _FakeBarcodeEngine fakeBarcode;
    late EdgeHttpServer server;
    late int port;
    late Uint8List samplePng;

    setUp(() async {
      fakeOcr = _FakeOcrEngine();
      fakeBarcode = _FakeBarcodeEngine();
      server = EdgeHttpServer(
        ocrEngine: fakeOcr,
        barcodeEngine: fakeBarcode,
      );
      port = await server.start(port: 0);
      samplePng = _createSamplePng();
    });

    tearDown(() async {
      await server.dispose();
    });

    test("POST /v1/ocr accepts multipart upload and cleans up temp file",
        () async {
      final client = HttpClient();
      addTearDown(client.close);

      const boundary = "droid-edge-boundary-123";
      final multipartBody = _buildMultipartBody(
        boundary: boundary,
        fieldName: "image",
        filename: "receipt.png",
        fileContentType: "image/png",
        fileBytes: samplePng,
        textFields: const {"script": "devanagari"},
      );

      final request = await client.post("127.0.0.1", port, "/v1/ocr");
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        "multipart/form-data; boundary=$boundary",
      );
      request.add(multipartBody);

      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();

      expect(response.statusCode, HttpStatus.ok);
      final json = jsonDecode(body) as Map<String, dynamic>;
      expect(json["status"], "ok");
      expect(json["script"], "devanagari");
      expect(json["text"], "TOTAL 42.50");
      expect(json["image_width"], 120);
      expect(json["image_height"], 60);
      expect(json["inference_ms"], 12);
      expect((json["blocks"] as List<dynamic>), hasLength(1));

      expect(fakeOcr.lastScript, OcrScript.devanagari);
      expect(fakeOcr.fileExistedDuringInference, isTrue);
      expect(fakeOcr.lastImageWidth, 120);
      expect(fakeOcr.lastImageHeight, 60);
      expect(await File(fakeOcr.lastTempFilePath!).exists(), isFalse);
    });

    test("POST /v1/ocr accepts raw binary image bytes with query script",
        () async {
      final client = HttpClient();
      addTearDown(client.close);

      final request =
          await client.post("127.0.0.1", port, "/v1/ocr?script=latin");
      request.headers.set(HttpHeaders.contentTypeHeader, "image/png");
      request.add(samplePng);

      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();

      expect(response.statusCode, HttpStatus.ok);
      final json = jsonDecode(body) as Map<String, dynamic>;
      expect(json["script"], "latin");
      expect(json["text"], "TOTAL 42.50");
      expect(await File(fakeOcr.lastTempFilePath!).exists(), isFalse);
    });

    test("POST /v1/ocr accepts base64 data URI in JSON payload", () async {
      final client = HttpClient();
      addTearDown(client.close);

      final dataUri = "data:image/png;base64,${base64Encode(samplePng)}";
      final request = await client.post("127.0.0.1", port, "/v1/ocr");
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        "application/json; charset=utf-8",
      );
      request.write(
        jsonEncode({
          "image": dataUri,
          "script": "japanese",
        }),
      );

      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();

      expect(response.statusCode, HttpStatus.ok);
      final json = jsonDecode(body) as Map<String, dynamic>;
      expect(json["script"], "japanese");
      expect(fakeOcr.lastScript, OcrScript.japanese);
      expect(await File(fakeOcr.lastTempFilePath!).exists(), isFalse);
    });

    test("POST /v1/ocr returns 400 for invalid script or empty/non-image body",
        () async {
      final client = HttpClient();
      addTearDown(client.close);

      final emptyReq = await client.post("127.0.0.1", port, "/v1/ocr");
      final emptyRes = await emptyReq.close();
      expect(emptyRes.statusCode, HttpStatus.badRequest);

      final invalidBytesReq = await client.post("127.0.0.1", port, "/v1/ocr");
      invalidBytesReq.headers
          .set(HttpHeaders.contentTypeHeader, "application/octet-stream");
      invalidBytesReq.add(utf8.encode("not-an-image"));
      final invalidBytesRes = await invalidBytesReq.close();
      expect(invalidBytesRes.statusCode, HttpStatus.badRequest);

      final badScriptReq =
          await client.post("127.0.0.1", port, "/v1/ocr?script=klingon");
      badScriptReq.headers.set(HttpHeaders.contentTypeHeader, "image/png");
      badScriptReq.add(samplePng);
      final badScriptRes = await badScriptReq.close();
      expect(badScriptRes.statusCode, HttpStatus.badRequest);
    });

    test("POST /v1/barcode accepts multipart, binary, and base64 JSON payloads",
        () async {
      final client = HttpClient();
      addTearDown(client.close);

      // 1. Multipart upload.
      const boundary = "barcode-boundary-456";
      final multipartBody = _buildMultipartBody(
        boundary: boundary,
        fieldName: "image",
        filename: "qr.png",
        fileContentType: "image/png",
        fileBytes: samplePng,
      );
      final multiReq = await client.post("127.0.0.1", port, "/v1/barcode");
      multiReq.headers.set(
        HttpHeaders.contentTypeHeader,
        "multipart/form-data; boundary=$boundary",
      );
      multiReq.add(multipartBody);
      final multiRes = await multiReq.close();
      final multiJson = jsonDecode(await utf8.decoder.bind(multiRes).join())
          as Map<String, dynamic>;
      expect(multiRes.statusCode, HttpStatus.ok);
      expect(multiJson["count"], 1);
      expect(
        (multiJson["barcodes"] as List<dynamic>).first["raw_value"],
        "http://android-edge.local:8080",
      );
      expect(fakeBarcode.fileExistedDuringInference, isTrue);
      expect(await File(fakeBarcode.lastTempFilePath!).exists(), isFalse);

      // 2. Raw binary upload.
      final binReq = await client.post("127.0.0.1", port, "/v1/barcode");
      binReq.headers.set(HttpHeaders.contentTypeHeader, "image/png");
      binReq.add(samplePng);
      final binRes = await binReq.close();
      expect(binRes.statusCode, HttpStatus.ok);
      expect(await File(fakeBarcode.lastTempFilePath!).exists(), isFalse);

      // 3. Base64 JSON upload.
      final jsonReq = await client.post("127.0.0.1", port, "/v1/barcode");
      jsonReq.headers
          .set(HttpHeaders.contentTypeHeader, "application/json");
      jsonReq.write(jsonEncode({"image": base64Encode(samplePng)}));
      final jsonRes = await jsonReq.close();
      expect(jsonRes.statusCode, HttpStatus.ok);
      expect(await File(fakeBarcode.lastTempFilePath!).exists(), isFalse);
    });

    test("POST /v1/barcode returns 400 on invalid payload and disposes engines",
        () async {
      final client = HttpClient();
      addTearDown(client.close);

      final badReq = await client.post("127.0.0.1", port, "/v1/barcode");
      badReq.headers.set(HttpHeaders.contentTypeHeader, "application/json");
      badReq.write(jsonEncode({"image": "%%%not-base64%%%"}));
      final badRes = await badReq.close();
      expect(badRes.statusCode, HttpStatus.badRequest);

      await server.dispose();
      expect(fakeOcr.disposed, isTrue);
      expect(fakeBarcode.disposed, isTrue);
    });

    test(
        "ImagePayloadProcessor flattens transparent RGBA PNG background to white",
        () async {
      final rgba = img.Image(width: 20, height: 20, numChannels: 4);
      // Set (0, 0) to transparent black (0, 0, 0, 0) and (10, 10) to opaque black (0, 0, 0, 255).
      rgba.setPixelRgba(0, 0, 0, 0, 0, 0);
      rgba.setPixelRgba(10, 10, 0, 0, 0, 255);
      final encodedPng = Uint8List.fromList(img.encodePng(rgba));

      final prepared = await ImagePayloadProcessor.prepareFromBytes(encodedPng);
      addTearDown(prepared.cleanup);

      final stagedBytes = await File(prepared.filePath).readAsBytes();
      final decodedStaged = img.decodePng(stagedBytes)!;

      final bgPixel = decodedStaged.getPixel(0, 0);
      expect(bgPixel.r, 255);
      expect(bgPixel.g, 255);
      expect(bgPixel.b, 255);

      final barPixel = decodedStaged.getPixel(10, 10);
      expect(barPixel.r, 0);
      expect(barPixel.g, 0);
      expect(barPixel.b, 0);
    });
  });
}

