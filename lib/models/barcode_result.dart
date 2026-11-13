import "package:equatable/equatable.dart";

import "geometry_models.dart";

class DetectedBarcodeItem extends Equatable {
  const DetectedBarcodeItem({
    required this.format,
    required this.valueType,
    this.rawValue,
    this.displayValue,
    this.boundingBox,
    this.cornerPoints = const [],
  });

  final String? rawValue;
  final String? displayValue;
  final String format;
  final String valueType;
  final BoundingBoxRect? boundingBox;
  final List<CornerPoint> cornerPoints;

  Map<String, dynamic> toJson() {
    return {
      "raw_value": rawValue,
      "display_value": displayValue,
      "format": format,
      "value_type": valueType,
      "bounding_box": boundingBox?.toJson(),
      "corner_points": cornerPoints.map((p) => p.toJson()).toList(),
    };
  }

  @override
  List<Object?> get props => [
        rawValue,
        displayValue,
        format,
        valueType,
        boundingBox,
        cornerPoints,
      ];
}

class BarcodeResult extends Equatable {
  const BarcodeResult({
    required this.barcodes,
    required this.inferenceMs,
    this.imageWidth,
    this.imageHeight,
  });

  final List<DetectedBarcodeItem> barcodes;
  final int inferenceMs;
  final int? imageWidth;
  final int? imageHeight;

  Map<String, dynamic> toJson() {
    return {
      "status": "ok",
      "count": barcodes.length,
      "image_width": imageWidth,
      "image_height": imageHeight,
      "inference_ms": inferenceMs,
      "barcodes": barcodes.map((b) => b.toJson()).toList(),
    };
  }

  @override
  List<Object?> get props => [
        barcodes,
        inferenceMs,
        imageWidth,
        imageHeight,
      ];
}

