import "dart:convert";
import "dart:io";
import "dart:math" as math;
import "dart:typed_data";

import "package:archive/archive.dart";
import "package:droid_edge_server/engines/face_detection_engine.dart";
import "package:droid_edge_server/engines/image_payload_processor.dart";
import "package:droid_edge_server/engines/ocr_engine.dart";
import "package:droid_edge_server/models/geometry_models.dart";
import "package:droid_edge_server/models/ocr_result.dart";
import "package:droid_edge_server/server/edge_http_server.dart";
import "package:flutter_test/flutter_test.dart";
import "package:image/image.dart" as img;
import "package:pdf/pdf.dart";

class _Phase5FakeOcrEngine implements OcrEngine {
  int callCount = 0;
  bool fileExistedDuringCall = false;
  bool disposed = false;

  @override
  Future<OcrResult> processImage(
    PreparedImagePayload payload, {
    OcrScript script = OcrScript.latin,
  }) async {
    callCount++;
    fileExistedDuringCall = await File(payload.filePath).exists();
    final width = payload.width ?? 400;
    final height = payload.height ?? 300;

    return OcrResult(
      text: "Invoice #INV-9981\n"
          "Card: 4111 1111 1111 4242\n"
          "SSN: 123-45-6789\n"
          "Email: alice@example.com\n"
          "Phone: +1 555-234-5678\n"
          "Address: 742 Evergreen Terrace, Springfield",
      script: script.name,
      detectedLanguages: const ["en"],
      inferenceMs: 14,
      imageWidth: width,
      imageHeight: height,
      blocks: const [
        OcrTextBlock(
          text: "Invoice #INV-9981",
          boundingBox: BoundingBoxRect(left: 20, top: 15, right: 200, bottom: 35),
          lines: [
            OcrTextLine(
              text: "Invoice #INV-9981",
              boundingBox:
                  BoundingBoxRect(left: 20, top: 15, right: 200, bottom: 35),
              elements: [
                OcrTextElement(
                  text: "Invoice",
                  boundingBox:
                      BoundingBoxRect(left: 20, top: 15, right: 95, bottom: 35),
                ),
                OcrTextElement(
                  text: "#INV-9981",
                  boundingBox:
                      BoundingBoxRect(left: 105, top: 15, right: 200, bottom: 35),
                ),
              ],
            ),
          ],
        ),
        OcrTextBlock(
          text: "Card: 4111 1111 1111 4242",
          boundingBox: BoundingBoxRect(left: 20, top: 45, right: 280, bottom: 65),
          lines: [
            OcrTextLine(
              text: "Card: 4111 1111 1111 4242",
              boundingBox:
                  BoundingBoxRect(left: 20, top: 45, right: 280, bottom: 65),
              elements: [
                OcrTextElement(
                  text: "Card:",
                  boundingBox:
                      BoundingBoxRect(left: 20, top: 45, right: 65, bottom: 65),
                ),
                OcrTextElement(
                  text: "4111",
                  boundingBox:
                      BoundingBoxRect(left: 72, top: 45, right: 118, bottom: 65),
                ),
                OcrTextElement(
                  text: "1111",
                  boundingBox:
                      BoundingBoxRect(left: 124, top: 45, right: 170, bottom: 65),
                ),
                OcrTextElement(
                  text: "1111",
                  boundingBox:
                      BoundingBoxRect(left: 176, top: 45, right: 222, bottom: 65),
                ),
                OcrTextElement(
                  text: "4242",
                  boundingBox:
                      BoundingBoxRect(left: 228, top: 45, right: 280, bottom: 65),
                ),
              ],
            ),
          ],
        ),
        OcrTextBlock(
          text: "SSN: 123-45-6789",
          boundingBox: BoundingBoxRect(left: 20, top: 80, right: 220, bottom: 100),
          lines: [
            OcrTextLine(
              text: "SSN: 123-45-6789",
              boundingBox:
                  BoundingBoxRect(left: 20, top: 80, right: 220, bottom: 100),
              elements: [
                OcrTextElement(
                  text: "SSN:",
                  boundingBox:
                      BoundingBoxRect(left: 20, top: 80, right: 65, bottom: 100),
                ),
                OcrTextElement(
                  text: "123-45-6789",
                  boundingBox:
                      BoundingBoxRect(left: 75, top: 80, right: 220, bottom: 100),
                ),
              ],
            ),
          ],
        ),
        OcrTextBlock(
          text: "Email: alice@example.com",
          boundingBox:
              BoundingBoxRect(left: 20, top: 115, right: 240, bottom: 135),
          lines: [
            OcrTextLine(
              text: "Email: alice@example.com",
              boundingBox:
                  BoundingBoxRect(left: 20, top: 115, right: 240, bottom: 135),
              elements: [
                OcrTextElement(
                  text: "Email:",
                  boundingBox:
                      BoundingBoxRect(left: 20, top: 115, right: 75, bottom: 135),
                ),
                OcrTextElement(
                  text: "alice@example.com",
                  boundingBox:
                      BoundingBoxRect(left: 82, top: 115, right: 240, bottom: 135),
                ),
              ],
            ),
          ],
        ),
        OcrTextBlock(
          text: "Phone: +1 555-234-5678",
          boundingBox:
              BoundingBoxRect(left: 20, top: 150, right: 240, bottom: 170),
          lines: [
            OcrTextLine(
              text: "Phone: +1 555-234-5678",
              boundingBox:
                  BoundingBoxRect(left: 20, top: 150, right: 240, bottom: 170),
              elements: [
                OcrTextElement(
                  text: "Phone:",
                  boundingBox:
                      BoundingBoxRect(left: 20, top: 150, right: 75, bottom: 170),
                ),
                OcrTextElement(
                  text: "+1",
                  boundingBox:
                      BoundingBoxRect(left: 82, top: 150, right: 108, bottom: 170),
                ),
                OcrTextElement(
                  text: "555-234-5678",
                  boundingBox:
                      BoundingBoxRect(left: 114, top: 150, right: 240, bottom: 170),
                ),
              ],
            ),
          ],
        ),
        OcrTextBlock(
          text: "Address: 742 Evergreen Terrace, Springfield",
          boundingBox:
              BoundingBoxRect(left: 20, top: 185, right: 360, bottom: 205),
          lines: [
            OcrTextLine(
              text: "Address: 742 Evergreen Terrace, Springfield",
              boundingBox:
                  BoundingBoxRect(left: 20, top: 185, right: 360, bottom: 205),
              elements: [
                OcrTextElement(
                  text: "Address:",
                  boundingBox:
                      BoundingBoxRect(left: 20, top: 185, right: 85, bottom: 205),
                ),
                OcrTextElement(
                  text: "742",
                  boundingBox:
                      BoundingBoxRect(left: 92, top: 185, right: 122, bottom: 205),
                ),
                OcrTextElement(
                  text: "Evergreen",
                  boundingBox:
                      BoundingBoxRect(left: 128, top: 185, right: 210, bottom: 205),
                ),
                OcrTextElement(
                  text: "Terrace,",
                  boundingBox:
                      BoundingBoxRect(left: 216, top: 185, right: 280, bottom: 205),
                ),
                OcrTextElement(
                  text: "Springfield",
                  boundingBox:
                      BoundingBoxRect(left: 286, top: 185, right: 360, bottom: 205),
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

class _Phase5FakeFaceEngine implements FaceDetectionEngine {
  bool disposed = false;

  @override
  Future<List<BoundingBoxRect>> detectFaces(PreparedImagePayload payload) async {
    return const [
      BoundingBoxRect(left: 290, top: 20, right: 370, bottom: 100),
    ];
  }

  @override
  Future<List<DetectedFaceRegion>> detectOrientedFaces(
    PreparedImagePayload payload,
  ) async {
    return const [
      DetectedFaceRegion(
        boundingBox: BoundingBoxRect(left: 290, top: 20, right: 370, bottom: 100),
      ),
    ];
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

Future<Uint8List?> _diskAssetLoader(String assetKey) async {
  final file = File(assetKey);
  if (!await file.exists()) return null;
  return file.readAsBytes();
}

/// Builds a bright test JPEG image with embedded EXIF Software & GPS metadata.
Uint8List _createMetadataTestJpeg({int width = 400, int height = 300}) {
  final canvas = img.Image(width: width, height: height, numChannels: 3);
  img.fill(canvas, color: img.ColorRgb8(245, 248, 252));
  canvas.exif.imageIfd["Software"] = "SecretPhoneCam 9.0";
  canvas.exif.gpsIfd["GPSLatitudeRef"] = "N";
  return Uint8List.fromList(img.encodeJpg(canvas, quality: 92));
}

/// Builds a high-entropy JPEG image so file size changes meaningfully across
/// JPEG quality and downscale steps.
Uint8List _createHighEntropyJpeg({int width = 900, int height = 1200}) {
  final rng = math.Random(42);
  final canvas = img.Image(width: width, height: height, numChannels: 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final r = (x * 13 + y * 7 + rng.nextInt(90)) % 256;
      final g = (x * 5 + y * 19 + rng.nextInt(90)) % 256;
      final b = (x * 11 + y * 3 + rng.nextInt(90)) % 256;
      canvas.setPixelRgb(x, y, r, g, b);
    }
  }
  return Uint8List.fromList(img.encodeJpg(canvas, quality: 95));
}

/// Builds an image-only PDF using `package:pdf` for testing scanned PDF input.
Future<Uint8List> _buildImageOnlyPdf(List<Uint8List> jpegPages) async {
  final doc = PdfDocument(compress: true);
  for (final jpeg in jpegPages) {
    final pdfImg = PdfImage.jpeg(doc, image: jpeg);
    final page = PdfPage(
      doc,
      pageFormat: PdfPageFormat(
        pdfImg.width.toDouble(),
        pdfImg.height.toDouble(),
      ),
    );
    page.getGraphics().drawImage(
          pdfImg,
          0,
          0,
          pdfImg.width.toDouble(),
          pdfImg.height.toDouble(),
        );
  }
  final stream = PdfStream();
  await doc.write(stream);
  return stream.output();
}

/// Extracts and inflates all PDF streams so tests can inspect generated PDF
/// operators (`3 Tr` invisible text layer) and embedded strings.
String _extractDecompressedPdfText(Uint8List pdfBytes) {
  final raw = latin1.decode(pdfBytes, allowInvalid: true);
  final buffer = StringBuffer(raw);
  final streamPattern = RegExp(r"stream\r?\n([\s\S]*?)endstream");
  for (final match in streamPattern.allMatches(raw)) {
    final start = match.start + match.group(0)!.indexOf(match.group(1)!);
    final end = start + match.group(1)!.length;
    var trimmedEnd = end;
    while (trimmedEnd > start &&
        (pdfBytes[trimmedEnd - 1] == 0x0A || pdfBytes[trimmedEnd - 1] == 0x0D)) {
      trimmedEnd--;
    }
    if (trimmedEnd <= start) continue;
    final slice = Uint8List.sublistView(pdfBytes, start, trimmedEnd);
    try {
      final inflated = zlib.decode(slice);
      buffer.writeln(latin1.decode(inflated, allowInvalid: true));
    } catch (_) {
      // Ignore non-zlib streams (such as DCTDecode JPEG streams).
    }
  }
  return buffer.toString();
}

Uint8List _buildMultiFileMultipartBody({
  required String boundary,
  required List<({String fieldName, String filename, String contentType, Uint8List bytes})>
      files,
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
  for (final file in files) {
    builder.add(
      utf8.encode(
        "--$boundary\r\n"
        "Content-Disposition: form-data; name=\"${file.fieldName}\"; "
        "filename=\"${file.filename}\"\r\n"
        "Content-Type: ${file.contentType}\r\n\r\n",
      ),
    );
    builder.add(file.bytes);
    builder.add(utf8.encode("\r\n"));
  }
  builder.add(utf8.encode("--$boundary--\r\n"));
  return builder.takeBytes();
}

void main() {
  group("Phase 5 Document Pipeline, Redaction & Batch Zip", () {
    late _Phase5FakeOcrEngine fakeOcr;
    late _Phase5FakeFaceEngine fakeFace;
    late EdgeHttpServer server;
    late int port;

    setUp(() async {
      fakeOcr = _Phase5FakeOcrEngine();
      fakeFace = _Phase5FakeFaceEngine();
      server = EdgeHttpServer(
        ocrEngine: fakeOcr,
        faceDetectionEngine: fakeFace,
        webAssetLoader: _diskAssetLoader,
      );
      port = await server.start(port: 0);
    });

    tearDown(() async {
      await server.dispose();
    });

    test(
        "POST /v1/doc/searchable-pdf builds A4 sandwich PDF with invisible text layer and strips metadata",
        () async {
      final img1 = _createMetadataTestJpeg(width: 400, height: 300);
      final img2 = _createMetadataTestJpeg(width: 300, height: 420);

      final client = HttpClient();
      addTearDown(client.close);

      const boundary = "phase5-pdf-boundary";
      final bodyBytes = _buildMultiFileMultipartBody(
        boundary: boundary,
        files: [
          (
            fieldName: "files",
            filename: "page1.jpg",
            contentType: "image/jpeg",
            bytes: img1,
          ),
          (
            fieldName: "files",
            filename: "page2.jpg",
            contentType: "image/jpeg",
            bytes: img2,
          ),
        ],
        textFields: const {
          "page_format": "a4",
          "enhance": "true",
          "response_format": "pdf",
        },
      );

      final req =
          await client.post("127.0.0.1", port, "/v1/doc/searchable-pdf");
      req.headers.set(
        HttpHeaders.authorizationHeader,
        "Bearer ${server.authToken}",
      );
      req.headers.set(
        HttpHeaders.contentTypeHeader,
        "multipart/form-data; boundary=$boundary",
      );
      req.add(bodyBytes);

      final res = await req.close();
      final responseBytes = Uint8List.fromList(
        await res.fold<List<int>>([], (acc, chunk) => acc..addAll(chunk)),
      );

      expect(res.statusCode, HttpStatus.ok);
      expect(res.headers.contentType?.mimeType, "application/pdf");
      expect(res.headers.value("x-page-count"), "2");
      expect(res.headers.value("x-metadata-stripped"), "true");
      expect(fakeOcr.callCount, 2);
      expect(fakeOcr.fileExistedDuringCall, isTrue);

      final pdfContent = _extractDecompressedPdfText(responseBytes);
      expect(pdfContent.startsWith("%PDF-"), isTrue);
      // Verify invisible text rendering mode (3 Tr) and OCR tokens are embedded.
      expect(pdfContent, contains("3 Tr"));
      expect(pdfContent, contains("Invoice"));
      expect(pdfContent, contains("#INV-9981"));
      expect(pdfContent, contains("Springfield"));
      // Verify A4 dimensions (~595.28 x 841.89 pt) and absent /Info dictionary.
      expect(pdfContent, contains("595.2"));
      expect(pdfContent, contains("841.8"));
      expect(pdfContent, isNot(contains("/Creator")));
      expect(pdfContent, isNot(contains("/Author")));
    });

    test(
        "POST /v1/doc/searchable-pdf accepts scanned PDF input, normalises to Letter, and honours max_size_mb",
        () async {
      final largePage1 = _createHighEntropyJpeg(width: 600, height: 800);
      final largePage2 = _createHighEntropyJpeg(width: 600, height: 800);
      final scannedPdf = await _buildImageOnlyPdf([largePage1, largePage2]);

      final client = HttpClient();
      addTearDown(client.close);

      final req = await client.post(
        "127.0.0.1",
        port,
        "/v1/doc/searchable-pdf?page_format=letter&max_size_mb=0.18&response_format=json",
      );
      req.headers.set(
        HttpHeaders.authorizationHeader,
        "Bearer ${server.authToken}",
      );
      req.headers.set(HttpHeaders.contentTypeHeader, "application/pdf");
      req.add(scannedPdf);

      final res = await req.close();
      final jsonText = await utf8.decoder.bind(res).join();

      expect(res.statusCode, HttpStatus.ok);
      final json = jsonDecode(jsonText) as Map<String, dynamic>;
      expect(json["status"], "ok");
      expect(json["page_count"], 2);
      expect(json["page_format"], "letter");
      expect(json["target_size_met"], isTrue);
      expect(json["byte_length"] as int, lessThanOrEqualTo((0.18 * 1024 * 1024).round()));
      expect(json["before_image_base64"], isNotEmpty);
      expect(json["after_image_base64"], isNotEmpty);

      final outPdfBytes = base64Decode(json["pdf_base64"] as String);
      final outPdfText = _extractDecompressedPdfText(outPdfBytes);
      expect(outPdfText, contains("3 Tr"));
      expect(outPdfText, contains("612"));
      expect(outPdfText, contains("792"));
    });

    test(
        "POST /v1/doc/redact permanently burns PII and face boxes and strips EXIF metadata",
        () async {
      final sourceJpeg = _createMetadataTestJpeg(width: 400, height: 300);
      final decodedSource = img.decodeJpg(sourceJpeg)!;
      expect(decodedSource.exif.isEmpty, isFalse);

      final client = HttpClient();
      addTearDown(client.close);

      final req = await client.post(
        "127.0.0.1",
        port,
        "/v1/doc/redact?presets=all&keep_last_4=false&output_format=image",
      );
      req.headers.set(
        HttpHeaders.authorizationHeader,
        "Bearer ${server.authToken}",
      );
      req.headers.set(HttpHeaders.contentTypeHeader, "image/jpeg");
      req.add(sourceJpeg);

      final res = await req.close();
      final outBytes = Uint8List.fromList(
        await res.fold<List<int>>([], (acc, chunk) => acc..addAll(chunk)),
      );

      expect(res.statusCode, HttpStatus.ok);
      expect(res.headers.contentType?.mimeType, "image/png");
      expect(res.headers.value("x-redacted-count"), "6");
      expect(res.headers.value("x-metadata-stripped"), "true");

      final sanitized = img.decodePng(outBytes)!;
      expect(sanitized.exif.isEmpty, isTrue);

      // Verify card box (x=90, y=55), email box (x=150, y=125),
      // address box (x=200, y=195), and face box (x=330, y=60) are burned to #11161D.
      for (final point in const [
        (90, 55),
        (150, 125),
        (200, 195),
        (330, 60),
      ]) {
        final pixel = sanitized.getPixel(point.$1, point.$2);
        expect(pixel.r, 17);
        expect(pixel.g, 22);
        expect(pixel.b, 29);
      }

      // Unmasked invoice header (x=50, y=25) remains bright background.
      final unmaskedPixel = sanitized.getPixel(50, 25);
      expect(unmaskedPixel.r, greaterThan(220));
    });

    test(
        "POST /v1/doc/redact with keep_last_4=true preserves final 4 digits and sanitises PDF text layer",
        () async {
      final sourceJpeg = _createMetadataTestJpeg(width: 400, height: 300);

      final client = HttpClient();
      addTearDown(client.close);

      final req = await client.post("127.0.0.1", port, "/v1/doc/redact");
      req.headers.set(
        HttpHeaders.authorizationHeader,
        "Bearer ${server.authToken}",
      );
      req.headers.set(
        HttpHeaders.contentTypeHeader,
        "application/json; charset=utf-8",
      );
      req.write(
        jsonEncode({
          "image": base64Encode(sourceJpeg),
          "presets": "ids",
          "keep_last_4": true,
          "output_format": "json",
        }),
      );

      final res = await req.close();
      final body = await utf8.decoder.bind(res).join();

      expect(res.statusCode, HttpStatus.ok);
      final json = jsonDecode(body) as Map<String, dynamic>;
      expect(json["redacted_count"], 2);
      expect(json["keep_last_4"], isTrue);
      expect(json["metadata_stripped"], isTrue);
      expect(json["sanitized_text"], contains("••••4242"));
      expect(json["sanitized_text"], contains("••••6789"));
      expect(json["sanitized_text"], isNot(contains("4111")));
      expect(json["sanitized_text"], isNot(contains("123-45-6789")));

      final afterImg = img.decodePng(
        base64Decode(json["after_image_base64"] as String),
      )!;
      // Leading card group "4111" (x=90, y=55) is burned out.
      final burnedCardStart = afterImg.getPixel(90, 55);
      expect(burnedCardStart.r, 17);
      expect(burnedCardStart.g, 22);
      expect(burnedCardStart.b, 29);

      // Trailing card group "4242" (x=254, y=55) remains visible/unmasked.
      final preservedLast4 = afterImg.getPixel(254, 55);
      expect(preservedLast4.r, greaterThan(220));

      // Single-element SSN "123-45-6789" [75..220]: left part burned, right part preserved.
      final burnedSsnLeft = afterImg.getPixel(100, 90);
      expect(burnedSsnLeft.r, 17);
      final preservedSsnRight = afterImg.getPixel(205, 90);
      expect(preservedSsnRight.r, greaterThan(220));

      // Sanitized PDF must not leak the masked prefix in its invisible text layer.
      final sanitizedPdfBytes = base64Decode(json["pdf_base64"] as String);
      final pdfText = _extractDecompressedPdfText(sanitizedPdfBytes);
      expect(pdfText, isNot(contains("4111")));
      expect(pdfText, isNot(contains("123-45-6789")));
      expect(pdfText, contains("4242"));
    });

    test(
        "POST /v1/doc/batch-zip sequentially processes files and returns valid ZIP with manifest",
        () async {
      final img1 = _createMetadataTestJpeg(width: 400, height: 300);
      final img2 = _createMetadataTestJpeg(width: 400, height: 300);

      final client = HttpClient();
      addTearDown(client.close);

      const boundary = "phase5-zip-boundary";
      final bodyBytes = _buildMultiFileMultipartBody(
        boundary: boundary,
        files: [
          (
            fieldName: "files",
            filename: "receipt_one.jpg",
            contentType: "image/jpeg",
            bytes: img1,
          ),
          (
            fieldName: "files",
            filename: "receipt_two.jpg",
            contentType: "image/jpeg",
            bytes: img2,
          ),
        ],
        textFields: const {
          "mode": "redact",
          "presets": "ids,faces",
          "keep_last_4": "true",
        },
      );

      final req = await client.post("127.0.0.1", port, "/v1/doc/batch-zip");
      req.headers.set(
        HttpHeaders.authorizationHeader,
        "Bearer ${server.authToken}",
      );
      req.headers.set(
        HttpHeaders.contentTypeHeader,
        "multipart/form-data; boundary=$boundary",
      );
      req.add(bodyBytes);

      final res = await req.close();
      final zipBytes = Uint8List.fromList(
        await res.fold<List<int>>([], (acc, chunk) => acc..addAll(chunk)),
      );

      expect(res.statusCode, HttpStatus.ok);
      expect(res.headers.contentType?.mimeType, "application/zip");
      expect(res.headers.value("x-batch-count"), "2");

      final archive = ZipDecoder().decodeBytes(zipBytes);
      final filenames = archive.files.map((f) => f.name).toSet();
      expect(
        filenames,
        containsAll([
          "receipt_one_redacted.png",
          "receipt_two_redacted.png",
          "manifest.json",
        ]),
      );

      final manifestFile =
          archive.files.firstWhere((f) => f.name == "manifest.json");
      final manifest =
          jsonDecode(utf8.decode(manifestFile.content)) as Map<String, dynamic>;
      expect(manifest["item_count"], 2);
      expect(manifest["operation"], "redact");
      expect(manifest["total_redacted"], 6);
    });

    test("Phase 5 endpoints return 400 Bad Request on invalid inputs", () async {
      final client = HttpClient();
      addTearDown(client.close);

      final emptyReq =
          await client.post("127.0.0.1", port, "/v1/doc/searchable-pdf");
      emptyReq.headers.set(
        HttpHeaders.authorizationHeader,
        "Bearer ${server.authToken}",
      );
      final emptyRes = await emptyReq.close();
      expect(emptyRes.statusCode, HttpStatus.badRequest);

      final badLimitReq = await client.post(
        "127.0.0.1",
        port,
        "/v1/doc/searchable-pdf?max_size_mb=-1",
      );
      badLimitReq.headers.set(
        HttpHeaders.authorizationHeader,
        "Bearer ${server.authToken}",
      );
      badLimitReq.headers.set(HttpHeaders.contentTypeHeader, "image/jpeg");
      badLimitReq.add(_createMetadataTestJpeg());
      final badLimitRes = await badLimitReq.close();
      expect(badLimitRes.statusCode, HttpStatus.badRequest);

      final badPresetReq = await client.post(
        "127.0.0.1",
        port,
        "/v1/doc/redact?presets=unknown_preset",
      );
      badPresetReq.headers.set(
        HttpHeaders.authorizationHeader,
        "Bearer ${server.authToken}",
      );
      badPresetReq.headers.set(HttpHeaders.contentTypeHeader, "image/jpeg");
      badPresetReq.add(_createMetadataTestJpeg());
      final badPresetRes = await badPresetReq.close();
      expect(badPresetRes.statusCode, HttpStatus.badRequest);

      await server.dispose();
      expect(fakeOcr.disposed, isTrue);
      expect(fakeFace.disposed, isTrue);
    });

    test("Phase 5 Web UI assets expose PDF, Redact, Compare & Batch Zip tools",
        () async {
      final client = HttpClient();
      addTearDown(client.close);

      final htmlRes = await (await client.get("127.0.0.1", port, "/")).close();
      final html = await utf8.decoder.bind(htmlRes).join();
      expect(htmlRes.statusCode, HttpStatus.ok);
      expect(html, contains("Searchable PDF"));
      expect(html, contains("PII Redact"));
      expect(html, contains("id=\"compareSlider\""));
      expect(html, contains("id=\"downloadBatchZipBtn\""));
      expect(html, contains("id=\"keepLast4Toggle\""));

      final jsRes =
          await (await client.get("127.0.0.1", port, "/app.js")).close();
      final js = await utf8.decoder.bind(jsRes).join();
      expect(jsRes.statusCode, HttpStatus.ok);
      expect(js, contains("/v1/doc/searchable-pdf"));
      expect(js, contains("/v1/doc/redact"));
      expect(js, contains("/v1/doc/batch-zip"));
    });

    test(
        "POST /v1/doc/redact detects and masks Indian Aadhaar (incl. Masked Aadhaar), PAN, GSTIN, Voter ID, +91 Mobile, UPI & PIN Address",
        () async {
      final indianOcr = _IndianKycFakeOcrEngine();
      final indianServer = EdgeHttpServer(
        ocrEngine: indianOcr,
        faceDetectionEngine: fakeFace,
        webAssetLoader: _diskAssetLoader,
      );
      final indianPort = await indianServer.start(port: 0);
      addTearDown(indianServer.dispose);

      final client = HttpClient();
      addTearDown(client.close);

      final sourceJpeg = _createMetadataTestJpeg(width: 600, height: 400);

      // Verify keep_last_4=true (UIDAI Masked Aadhaar mode).
      final req = await client.post("127.0.0.1", indianPort, "/v1/doc/redact");
      req.headers.set(
        HttpHeaders.authorizationHeader,
        "Bearer ${indianServer.authToken}",
      );
      req.headers.set(
        HttpHeaders.contentTypeHeader,
        "application/json; charset=utf-8",
      );
      req.write(
        jsonEncode({
          "image": base64Encode(sourceJpeg),
          "presets": "aadhaar,pan,upi,pin,faces",
          "keep_last_4": true,
          "output_format": "json",
        }),
      );

      final res = await req.close();
      final body = await utf8.decoder.bind(res).join();

      expect(res.statusCode, HttpStatus.ok);
      final json = jsonDecode(body) as Map<String, dynamic>;
      final sanitizedText = json["sanitized_text"] as String;
      final counts = json["category_counts"] as Map<String, dynamic>;

      // 6 IDs (Aadhaar, Devanagari Aadhaar, PAN, GSTIN, Voter ID, IFSC)
      expect(counts["id"], 6);
      // 2 contacts (+91 mobile, UPI VPA)
      expect(counts["contact"], 2);
      // 1 Indian address line with PIN 560038
      expect(counts["address"], 1);
      // 1 face
      expect(counts["face"], 1);

      expect(sanitizedText, contains("••••5123"));
      expect(sanitizedText, isNot(contains("4821")));
      expect(sanitizedText, isNot(contains("ABCDE1234F")));
      expect(sanitizedText, isNot(contains("29ABCDE1234F1Z5")));
      expect(sanitizedText, isNot(contains("XYZ1234567")));
      expect(sanitizedText, isNot(contains("SBIN0004321")));
      expect(sanitizedText, isNot(contains("98765")));
      expect(sanitizedText, isNot(contains("arjun.sharma@okicici")));
      expect(sanitizedText, isNot(contains("560038")));
      expect(sanitizedText, contains("[REDACTED UPI]"));
      expect(sanitizedText, contains("[REDACTED PHONE]"));
      expect(sanitizedText, contains("[REDACTED ADDRESS]"));

      // Verify first 8 digits of Aadhaar are burned out while last 4 ("5123") remain bright.
      final afterImg = img.decodePng(
        base64Decode(json["after_image_base64"] as String),
      )!;
      final maskedAadhaarPrefix = afterImg.getPixel(130, 50);
      expect(maskedAadhaarPrefix.r, 17);
      expect(maskedAadhaarPrefix.g, 22);
      expect(maskedAadhaarPrefix.b, 29);

      final visibleAadhaarLast4 = afterImg.getPixel(270, 50);
      expect(visibleAadhaarLast4.r, greaterThan(220));
    });
  });
}

class _IndianKycFakeOcrEngine implements OcrEngine {
  @override
  Future<OcrResult> processImage(
    PreparedImagePayload payload, {
    OcrScript script = OcrScript.latin,
  }) async {
    return OcrResult(
      text: "Aadhaar: 4821 9304 5123\n"
          "आधार: ४८२१ ९३०४ ७८९०\n"
          "PAN: ABCDE1234F\n"
          "GSTIN: 29ABCDE1234F1Z5\n"
          "Voter ID: XYZ1234567\n"
          "IFSC: SBIN0004321\n"
          "Mobile: +91 98765 43210\n"
          "UPI: arjun.sharma@okicici\n"
          "Flat 402, Indiranagar 2nd Stage, Bengaluru - 560038",
      script: script.name,
      detectedLanguages: const ["en", "hi"],
      inferenceMs: 16,
      imageWidth: payload.width ?? 600,
      imageHeight: payload.height ?? 400,
      blocks: const [
        OcrTextBlock(
          text: "Indian KYC Document",
          boundingBox: BoundingBoxRect(left: 20, top: 20, right: 560, bottom: 380),
          lines: [
            OcrTextLine(
              text: "Aadhaar: 4821 9304 5123",
              boundingBox:
                  BoundingBoxRect(left: 20, top: 40, right: 290, bottom: 60),
              elements: [
                OcrTextElement(
                  text: "Aadhaar:",
                  boundingBox:
                      BoundingBoxRect(left: 20, top: 40, right: 100, bottom: 60),
                ),
                OcrTextElement(
                  text: "4821",
                  boundingBox:
                      BoundingBoxRect(left: 110, top: 40, right: 160, bottom: 60),
                ),
                OcrTextElement(
                  text: "9304",
                  boundingBox:
                      BoundingBoxRect(left: 170, top: 40, right: 220, bottom: 60),
                ),
                OcrTextElement(
                  text: "5123",
                  boundingBox:
                      BoundingBoxRect(left: 230, top: 40, right: 290, bottom: 60),
                ),
              ],
            ),
            OcrTextLine(
              text: "आधार: ४८२१ ९३०४ ७८९०",
              boundingBox:
                  BoundingBoxRect(left: 20, top: 75, right: 290, bottom: 95),
            ),
            OcrTextLine(
              text: "PAN: ABCDE1234F",
              boundingBox:
                  BoundingBoxRect(left: 20, top: 110, right: 220, bottom: 130),
            ),
            OcrTextLine(
              text: "GSTIN: 29ABCDE1234F1Z5",
              boundingBox:
                  BoundingBoxRect(left: 20, top: 145, right: 290, bottom: 165),
            ),
            OcrTextLine(
              text: "Voter ID: XYZ1234567",
              boundingBox:
                  BoundingBoxRect(left: 20, top: 180, right: 240, bottom: 200),
            ),
            OcrTextLine(
              text: "IFSC: SBIN0004321",
              boundingBox:
                  BoundingBoxRect(left: 20, top: 215, right: 230, bottom: 235),
            ),
            OcrTextLine(
              text: "Mobile: +91 98765 43210",
              boundingBox:
                  BoundingBoxRect(left: 20, top: 250, right: 270, bottom: 270),
            ),
            OcrTextLine(
              text: "UPI: arjun.sharma@okicici",
              boundingBox:
                  BoundingBoxRect(left: 20, top: 285, right: 290, bottom: 305),
            ),
            OcrTextLine(
              text: "Flat 402, Indiranagar 2nd Stage, Bengaluru - 560038",
              boundingBox:
                  BoundingBoxRect(left: 20, top: 320, right: 520, bottom: 340),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Future<void> dispose() async {}
}
