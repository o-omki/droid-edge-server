import "package:equatable/equatable.dart";

import "geometry_models.dart";

enum OcrScript {
  latin,
  devanagari,
  chinese,
  japanese,
  korean;

  /// Parses a script name (case-insensitive), defaulting to [OcrScript.latin]
  /// when [raw] is null or blank.
  static OcrScript fromName(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return OcrScript.latin;
    }
    final normalized = raw.trim().toLowerCase();
    for (final script in OcrScript.values) {
      if (script.name == normalized) {
        return script;
      }
    }
    throw FormatException(
      "Unsupported OCR script \"$raw\". Supported values: "
      "${OcrScript.values.map((s) => s.name).join(", ")}.",
    );
  }
}

/// Word-level text element recognised within an [OcrTextLine].
class OcrTextElement extends Equatable {
  const OcrTextElement({
    required this.text,
    this.boundingBox,
    this.cornerPoints = const [],
    this.recognizedLanguages = const [],
    this.confidence,
  });

  final String text;
  final BoundingBoxRect? boundingBox;
  final List<CornerPoint> cornerPoints;
  final List<String> recognizedLanguages;
  final double? confidence;

  Map<String, dynamic> toJson() {
    return {
      "text": text,
      "bounding_box": boundingBox?.toJson(),
      "corner_points": cornerPoints.map((p) => p.toJson()).toList(),
      "recognized_languages": recognizedLanguages,
      "confidence": confidence,
    };
  }

  @override
  List<Object?> get props => [
        text,
        boundingBox,
        cornerPoints,
        recognizedLanguages,
        confidence,
      ];
}

/// Line-level text segment recognised within an [OcrTextBlock].
class OcrTextLine extends Equatable {
  const OcrTextLine({
    required this.text,
    this.boundingBox,
    this.cornerPoints = const [],
    this.recognizedLanguages = const [],
    this.confidence,
    this.elements = const [],
  });

  final String text;
  final BoundingBoxRect? boundingBox;
  final List<CornerPoint> cornerPoints;
  final List<String> recognizedLanguages;
  final double? confidence;
  final List<OcrTextElement> elements;

  Map<String, dynamic> toJson() {
    return {
      "text": text,
      "bounding_box": boundingBox?.toJson(),
      "corner_points": cornerPoints.map((p) => p.toJson()).toList(),
      "recognized_languages": recognizedLanguages,
      "confidence": confidence,
      "elements": elements.map((e) => e.toJson()).toList(),
    };
  }

  @override
  List<Object?> get props => [
        text,
        boundingBox,
        cornerPoints,
        recognizedLanguages,
        confidence,
        elements,
      ];
}

/// Paragraph or region block recognised within an [OcrResult].
class OcrTextBlock extends Equatable {
  const OcrTextBlock({
    required this.text,
    this.boundingBox,
    this.cornerPoints = const [],
    this.recognizedLanguages = const [],
    this.lines = const [],
  });

  final String text;
  final BoundingBoxRect? boundingBox;
  final List<CornerPoint> cornerPoints;
  final List<String> recognizedLanguages;
  final List<OcrTextLine> lines;

  Map<String, dynamic> toJson() {
    return {
      "text": text,
      "bounding_box": boundingBox?.toJson(),
      "corner_points": cornerPoints.map((p) => p.toJson()).toList(),
      "recognized_languages": recognizedLanguages,
      "lines": lines.map((l) => l.toJson()).toList(),
    };
  }

  @override
  List<Object?> get props => [
        text,
        boundingBox,
        cornerPoints,
        recognizedLanguages,
        lines,
      ];
}

class OcrResult extends Equatable {
  const OcrResult({
    required this.text,
    required this.script,
    required this.blocks,
    required this.detectedLanguages,
    required this.inferenceMs,
    this.imageWidth,
    this.imageHeight,
  });

  final String text;
  final String script;
  final List<OcrTextBlock> blocks;
  final List<String> detectedLanguages;
  final int inferenceMs;
  final int? imageWidth;
  final int? imageHeight;

  Map<String, dynamic> toJson() {
    return {
      "status": "ok",
      "script": script,
      "text": text,
      "detected_languages": detectedLanguages,
      "image_width": imageWidth,
      "image_height": imageHeight,
      "inference_ms": inferenceMs,
      "blocks": blocks.map((b) => b.toJson()).toList(),
    };
  }

  @override
  List<Object?> get props => [
        text,
        script,
        blocks,
        detectedLanguages,
        inferenceMs,
        imageWidth,
        imageHeight,
      ];
}

