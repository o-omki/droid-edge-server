import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:droid_edge_server/engines/face_detection_engine.dart";
import "package:droid_edge_server/engines/image_payload_processor.dart";
import "package:droid_edge_server/engines/ocr_engine.dart";
import "package:droid_edge_server/engines/pdf_rasterizer.dart";
import "package:droid_edge_server/engines/pii_redaction_engine.dart";
import "package:droid_edge_server/engines/searchable_pdf_engine.dart";
import "package:droid_edge_server/models/document_pipeline_models.dart";
import "package:droid_edge_server/models/geometry_models.dart";
import "package:droid_edge_server/models/ocr_result.dart";
import "package:flutter_test/flutter_test.dart";
import "package:image/image.dart" as img;

void main() {
  group("Rotated Image Alignment", () {
    test(
      "ImagePayloadProcessor bakes EXIF orientation so dimensions match upright pixels",
      () async {
        // Create a 300x120 JPEG tagged with EXIF orientation 6 (90° CW).
        final raw = img.Image(width: 300, height: 120);
        img.fill(raw, color: img.ColorRgb8(255, 255, 255));
        raw.exif.imageIfd.orientation = 6;
        final jpegBytes = Uint8List.fromList(img.encodeJpg(raw, quality: 90));

        final prepared = await ImagePayloadProcessor.prepareFromBytes(
          jpegBytes,
        );
        try {
          expect(prepared.width, 120);
          expect(prepared.height, 300);

          final bakedBytes = await File(prepared.filePath).readAsBytes();
          final decoded = img.decodeImage(bakedBytes);
          expect(decoded, isNotNull);
          expect(decoded!.width, 120);
          expect(decoded.height, 300);
        } finally {
          await prepared.cleanup();
        }
      },
    );

    test(
      "PiiRedactionEngine burns oriented polygon masks and emits corner_points for rotated text",
      () async {
        // Diagonal text band from (40, 40) to (240, 140) (~26.6° tilt).
        // Height ~20px perpendicular to the text.
        // p0=(40, 40), p1=(240, 140), p2=(231, 158), p3=(31, 58)
        final ocr = _TiltedPhoneFakeOcrEngine();
        final faces = _EmptyFaceEngine();
        final engine = PiiRedactionEngine(
          ocrEngine: ocr,
          faceDetectionEngine: faces,
          pdfRasterizer: _NoOpPdfRasterizer(),
        );

        final canvas = img.Image(width: 320, height: 240);
        img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
        final pngBytes = Uint8List.fromList(img.encodePng(canvas));

        final result = await engine.redactPayloads(
          [pngBytes],
          options: const RedactionOptions(
            presets: {RedactionPreset.contacts},
            outputFormat: RedactionOutputFormat.image,
            stripMetadata: true,
          ),
        );

        expect(result.regions, hasLength(1));
        final region = result.regions.first;
        expect(region.cornerPoints, hasLength(4));

        // Verify the polygon corners are tilted (y differs between p0 and p1).
        expect(
          (region.cornerPoints[1].y - region.cornerPoints[0].y).abs(),
          greaterThan(50),
        );

        final afterImg = img.decodePng(result.outputBytes)!;

        // Midpoint of the tilted line (~140, 99) MUST be masked to dark colour.
        final midPixel = afterImg.getPixel(140, 99);
        expect(midPixel.r, 17);
        expect(midPixel.g, 22);
        expect(midPixel.b, 29);

        // Top-right corner of the axis-aligned bounding box (235, 45) is far
        // from the tilted text band and MUST remain unmasked white!
        final offAxisPixel = afterImg.getPixel(235, 45);
        expect(offAxisPixel.r, 255);
        expect(offAxisPixel.g, 255);
        expect(offAxisPixel.b, 255);
      },
    );

    test(
      "SearchablePdfEngine applies rotated transform for tilted OCR corner_points",
      () async {
        final ocr = _TiltedPhoneFakeOcrEngine();
        final engine = SearchablePdfEngine(
          ocrEngine: ocr,
          pdfRasterizer: _NoOpPdfRasterizer(),
        );

        final canvas = img.Image(width: 320, height: 240);
        img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
        final pngBytes = Uint8List.fromList(img.encodePng(canvas));

        final result = await engine.generateFromPayloads(
          [pngBytes],
          options: const SearchablePdfOptions(
            pageFormat: PageNormalizationFormat.a4,
          ),
        );

        expect(result.pdfBytes.length, greaterThan(200));
        expect(utf8.decode(result.pdfBytes.sublist(0, 5)), "%PDF-");
        expect(result.pages, hasLength(1));
        expect(result.pages.first.characterCount, greaterThan(0));
      },
    );

    test("Web UI app.js renders polygon overlays using corner_points", () async {
      final jsContent = await File("assets/web/app.js").readAsString();
      expect(jsContent, contains("corner_points"));
      expect(jsContent, contains("\"polygon\""));
    });

    test(
      "Face redaction uses headEulerAngleZ to burn an oriented polygon instead of an axis-aligned box",
      () async {
        // Face tilted ~25° CCW inside a 100x120 AABB at (60, 40) -> (160, 160).
        const aabb = BoundingBoxRect(
          left: 60,
          top: 40,
          right: 160,
          bottom: 160,
        );
        final corners = MlKitFaceDetectionEngine.orientedCornersFromAngle(
          aabb,
          25.0,
        );
        expect(corners, hasLength(4));
        // CCW tilt means top-right corner (p1) has a smaller y than top-left (p0).
        expect(corners[1].y, lessThan(corners[0].y));

        final engine = PiiRedactionEngine(
          ocrEngine: _EmptyOcrEngine(),
          faceDetectionEngine: _OrientedFakeFaceEngine(
            DetectedFaceRegion(boundingBox: aabb, cornerPoints: corners),
          ),
          pdfRasterizer: _NoOpPdfRasterizer(),
        );

        final canvas = img.Image(width: 240, height: 220);
        img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
        final pngBytes = Uint8List.fromList(img.encodePng(canvas));

        final result = await engine.redactPayloads(
          [pngBytes],
          options: const RedactionOptions(
            presets: {RedactionPreset.faces},
            outputFormat: RedactionOutputFormat.image,
          ),
        );

        expect(result.regions, hasLength(1));
        expect(result.regions.first.category, "face");
        expect(result.regions.first.cornerPoints, corners);

        final afterImg = img.decodePng(result.outputBytes)!;
        // Centre of the face (110, 100) MUST be masked.
        final centerPx = afterImg.getPixel(110, 100);
        expect(centerPx.r, 17);
        expect(centerPx.g, 22);
        expect(centerPx.b, 29);

        // Top-left corner of the axis-aligned box (62, 42) is outside the
        // rotated face rectangle and MUST remain unmasked white.
        final cornerPx = afterImg.getPixel(62, 42);
        expect(cornerPx.r, 255);
        expect(cornerPx.g, 255);
        expect(cornerPx.b, 255);
      },
    );
  });
}

class _TiltedPhoneFakeOcrEngine implements OcrEngine {
  @override
  Future<OcrResult> processImage(
    PreparedImagePayload payload, {
    OcrScript script = OcrScript.latin,
  }) async {
    const corners = [
      CornerPoint(x: 40, y: 40),
      CornerPoint(x: 240, y: 140),
      CornerPoint(x: 231, y: 158),
      CornerPoint(x: 31, y: 58),
    ];
    const bbox = BoundingBoxRect(
      left: 31,
      top: 40,
      right: 240,
      bottom: 158,
    );

    return const OcrResult(
      text: "+1-555-234-5678",
      script: "latin",
      detectedLanguages: ["en"],
      inferenceMs: 5,
      imageWidth: 320,
      imageHeight: 240,
      blocks: [
        OcrTextBlock(
          text: "+1-555-234-5678",
          boundingBox: bbox,
          cornerPoints: corners,
          lines: [
            OcrTextLine(
              text: "+1-555-234-5678",
              boundingBox: bbox,
              cornerPoints: corners,
              elements: [
                OcrTextElement(
                  text: "+1-555-234-5678",
                  boundingBox: bbox,
                  cornerPoints: corners,
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  @override
  Future<void> dispose() async {}
}

class _EmptyFaceEngine implements FaceDetectionEngine {
  @override
  Future<List<BoundingBoxRect>> detectFaces(
    PreparedImagePayload payload,
  ) async =>
      const [];

  @override
  Future<List<DetectedFaceRegion>> detectOrientedFaces(
    PreparedImagePayload payload,
  ) async =>
      const [];

  @override
  Future<void> dispose() async {}
}

class _EmptyOcrEngine implements OcrEngine {
  @override
  Future<OcrResult> processImage(
    PreparedImagePayload payload, {
    OcrScript script = OcrScript.latin,
  }) async {
    return OcrResult(
      text: "",
      script: script.name,
      detectedLanguages: const [],
      inferenceMs: 1,
      imageWidth: payload.width ?? 240,
      imageHeight: payload.height ?? 220,
      blocks: const [],
    );
  }

  @override
  Future<void> dispose() async {}
}

class _OrientedFakeFaceEngine implements FaceDetectionEngine {
  _OrientedFakeFaceEngine(this.face);

  final DetectedFaceRegion face;

  @override
  Future<List<BoundingBoxRect>> detectFaces(
    PreparedImagePayload payload,
  ) async =>
      [face.boundingBox];

  @override
  Future<List<DetectedFaceRegion>> detectOrientedFaces(
    PreparedImagePayload payload,
  ) async =>
      [face];

  @override
  Future<void> dispose() async {}
}

class _NoOpPdfRasterizer implements PdfRasterizer {
  @override
  Future<List<RasterizedPdfPage>> rasterizePdf(
    Uint8List pdfBytes, {
    double dpi = 150.0,
  }) async =>
      const [];

  @override
  Future<void> dispose() async {}
}
