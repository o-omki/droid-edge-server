import "dart:math";
import "dart:ui";

import "package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart";

import "../models/geometry_models.dart";
import "../models/ocr_result.dart";
import "image_payload_processor.dart";

abstract class OcrEngine {
  /// Runs OCR inference on a staged [payload] using the requested [script].
  Future<OcrResult> processImage(
    PreparedImagePayload payload, {
    OcrScript script = OcrScript.latin,
  });

  Future<void> dispose();
}

/// Hardware-accelerated on-device OCR engine backed by bundled Google ML Kit
/// Text Recognition v2 models.
class MlKitOcrEngine implements OcrEngine {
  final Map<OcrScript, TextRecognizer> _recognizers = {};

  @override
  Future<OcrResult> processImage(
    PreparedImagePayload payload, {
    OcrScript script = OcrScript.latin,
  }) async {
    final recognizer = _recognizers.putIfAbsent(
      script,
      () => TextRecognizer(script: _mapScript(script)),
    );

    final inputImage = InputImage.fromFilePath(payload.filePath);
    final stopwatch = Stopwatch()..start();
    final recognized = await recognizer.processImage(inputImage);
    stopwatch.stop();

    final detectedLanguages = <String>{};
    final blocks = recognized.blocks.map((block) {
      final blockLangs = _filterLanguages(block.recognizedLanguages);
      detectedLanguages.addAll(blockLangs);

      final lines = block.lines.map((line) {
        final lineLangs = _filterLanguages(line.recognizedLanguages);
        detectedLanguages.addAll(lineLangs);

        final elements = line.elements.map((element) {
          final elemLangs = _filterLanguages(element.recognizedLanguages);
          detectedLanguages.addAll(elemLangs);

          return OcrTextElement(
            text: element.text,
            boundingBox: _toBoundingBox(element.boundingBox),
            cornerPoints: _toCornerPoints(element.cornerPoints),
            recognizedLanguages: elemLangs,
            confidence: element.confidence,
          );
        }).toList();

        return OcrTextLine(
          text: line.text,
          boundingBox: _toBoundingBox(line.boundingBox),
          cornerPoints: _toCornerPoints(line.cornerPoints),
          recognizedLanguages: lineLangs,
          confidence: line.confidence,
          elements: elements,
        );
      }).toList();

      return OcrTextBlock(
        text: block.text,
        boundingBox: _toBoundingBox(block.boundingBox),
        cornerPoints: _toCornerPoints(block.cornerPoints),
        recognizedLanguages: blockLangs,
        lines: lines,
      );
    }).toList();

    return OcrResult(
      text: recognized.text,
      script: script.name,
      blocks: blocks,
      detectedLanguages: detectedLanguages.toList(),
      inferenceMs: stopwatch.elapsedMilliseconds,
      imageWidth: payload.width,
      imageHeight: payload.height,
    );
  }

  @override
  Future<void> dispose() async {
    for (final recognizer in _recognizers.values) {
      await recognizer.close();
    }
    _recognizers.clear();
  }

  static TextRecognitionScript _mapScript(OcrScript script) {
    switch (script) {
      case OcrScript.latin:
        return TextRecognitionScript.latin;
      case OcrScript.devanagari:
        return TextRecognitionScript.devanagiri;
      case OcrScript.chinese:
        return TextRecognitionScript.chinese;
      case OcrScript.japanese:
        return TextRecognitionScript.japanese;
      case OcrScript.korean:
        return TextRecognitionScript.korean;
    }
  }

  static List<String> _filterLanguages(List<String> languages) {
    return languages
        .where((lang) => lang.isNotEmpty && lang != "und")
        .toList();
  }

  static BoundingBoxRect _toBoundingBox(Rect rect) {
    return BoundingBoxRect(
      left: rect.left,
      top: rect.top,
      right: rect.right,
      bottom: rect.bottom,
    );
  }

  static List<CornerPoint> _toCornerPoints(List<Point<int>> points) {
    return points
        .map((point) => CornerPoint(x: point.x, y: point.y))
        .toList();
  }
}
