import "dart:math";
import "dart:ui";

import "package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart";

import "../models/barcode_result.dart";
import "../models/geometry_models.dart";
import "image_payload_processor.dart";

abstract class BarcodeEngine {
  /// Scans a staged [payload] and returns all decoded barcodes.
  Future<BarcodeResult> processImage(PreparedImagePayload payload);

  Future<void> dispose();
}

/// Hardware-accelerated barcode scanner backed by the bundled Google ML Kit
/// Barcode Scanning model.
class MlKitBarcodeEngine implements BarcodeEngine {
  BarcodeScanner? _scanner;

  @override
  Future<BarcodeResult> processImage(PreparedImagePayload payload) async {
    final scanner = _scanner ??= BarcodeScanner(
      formats: const [BarcodeFormat.all],
    );

    final inputImage = InputImage.fromFilePath(payload.filePath);
    final stopwatch = Stopwatch()..start();
    final detected = await scanner.processImage(inputImage);
    stopwatch.stop();

    final items = detected.map((barcode) {
      return DetectedBarcodeItem(
        rawValue: barcode.rawValue,
        displayValue: barcode.displayValue,
        format: barcode.format.name,
        valueType: barcode.type.name,
        boundingBox: _toBoundingBox(barcode.boundingBox),
        cornerPoints: _toCornerPoints(barcode.cornerPoints),
      );
    }).toList();

    return BarcodeResult(
      barcodes: items,
      inferenceMs: stopwatch.elapsedMilliseconds,
      imageWidth: payload.width,
      imageHeight: payload.height,
    );
  }

  @override
  Future<void> dispose() async {
    final scanner = _scanner;
    _scanner = null;
    if (scanner != null) {
      await scanner.close();
    }
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

