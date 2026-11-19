import "dart:convert";
import "dart:typed_data";

import "package:equatable/equatable.dart";

import "geometry_models.dart";
import "ocr_result.dart";

enum PageNormalizationFormat {
  original,
  a4,
  letter;

  /// Parses a normalisation format name (case-insensitive), defaulting to
  /// [PageNormalizationFormat.a4] when [raw] is null or blank.
  static PageNormalizationFormat fromName(
    String? raw, {
    PageNormalizationFormat fallback = PageNormalizationFormat.a4,
  }) {
    if (raw == null || raw.trim().isEmpty) {
      return fallback;
    }
    final normalized = raw.trim().toLowerCase();
    for (final format in PageNormalizationFormat.values) {
      if (format.name == normalized) {
        return format;
      }
    }
    throw FormatException(
      "Unsupported page format \"$raw\". Supported values: "
      "${PageNormalizationFormat.values.map((f) => f.name).join(", ")}.",
    );
  }
}

class SearchablePdfOptions extends Equatable {
  const SearchablePdfOptions({
    this.pageFormat = PageNormalizationFormat.a4,
    this.enhanceContrast = true,
    this.contrast = 1.18,
    this.brightness = 1.02,
    this.maxSizeMb,
    this.script = OcrScript.latin,
    this.stripMetadata = true,
    this.includePreviews = false,
  });

  final PageNormalizationFormat pageFormat;
  final bool enhanceContrast;
  final double contrast;
  final double brightness;
  final double? maxSizeMb;
  final OcrScript script;
  final bool stripMetadata;
  final bool includePreviews;

  @override
  List<Object?> get props => [
        pageFormat,
        enhanceContrast,
        contrast,
        brightness,
        maxSizeMb,
        script,
        stripMetadata,
        includePreviews,
      ];
}

enum RedactionPreset {
  ids,
  contacts,
  addresses,
  faces;

  static const Set<RedactionPreset> allPresets = {
    RedactionPreset.ids,
    RedactionPreset.contacts,
    RedactionPreset.addresses,
    RedactionPreset.faces,
  };

  /// Parses a comma-separated preset string (such as `"ids,contacts,faces"` or
  /// `"all"`), defaulting to all presets when [raw] is null or blank.
  static Set<RedactionPreset> parsePresets(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return Set<RedactionPreset>.from(allPresets);
    }
    final tokens = raw
        .split(",")
        .map((token) => token.trim().toLowerCase())
        .where((token) => token.isNotEmpty)
        .toList();
    if (tokens.isEmpty || tokens.contains("all")) {
      return Set<RedactionPreset>.from(allPresets);
    }

    final parsed = <RedactionPreset>{};
    for (final token in tokens) {
      switch (token) {
        case "id":
        case "ids":
        case "card":
        case "cards":
        case "account":
        case "accounts":
        case "aadhaar":
        case "aadhar":
        case "pan":
        case "gstin":
        case "voter":
          parsed.add(RedactionPreset.ids);
          break;
        case "contact":
        case "contacts":
        case "phone":
        case "phones":
        case "email":
        case "emails":
        case "upi":
          parsed.add(RedactionPreset.contacts);
          break;
        case "address":
        case "addresses":
        case "pin":
        case "pincode":
          parsed.add(RedactionPreset.addresses);
          break;
        case "face":
        case "faces":
          parsed.add(RedactionPreset.faces);
          break;
        default:
          throw FormatException(
            "Unsupported redaction preset \"$token\". Supported values: "
            "all, ids, contacts, addresses, faces.",
          );
      }
    }
    return parsed;
  }
}

/// Output representation returned by `POST /v1/doc/redact`.
enum RedactionOutputFormat {
  image,
  pdf,
  json;

  /// Parses an output format name (case-insensitive), defaulting to
  /// [RedactionOutputFormat.image] when [raw] is null or blank.
  static RedactionOutputFormat fromName(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return RedactionOutputFormat.image;
    }
    final normalized = raw.trim().toLowerCase();
    for (final format in RedactionOutputFormat.values) {
      if (format.name == normalized) {
        return format;
      }
    }
    throw FormatException(
      "Unsupported redaction output format \"$raw\". Supported values: "
      "${RedactionOutputFormat.values.map((f) => f.name).join(", ")}.",
    );
  }
}

/// Configuration options for on-device PII redaction and metadata stripping.
class RedactionOptions extends Equatable {
  const RedactionOptions({
    this.presets = RedactionPreset.allPresets,
    this.keepLast4 = false,
    this.enhanceContrast = false,
    this.stripMetadata = true,
    this.outputFormat = RedactionOutputFormat.image,
    this.script = OcrScript.latin,
    this.pageFormat = PageNormalizationFormat.original,
  });

  final Set<RedactionPreset> presets;
  final bool keepLast4;
  final bool enhanceContrast;
  final bool stripMetadata;
  final RedactionOutputFormat outputFormat;
  final OcrScript script;
  final PageNormalizationFormat pageFormat;

  @override
  List<Object?> get props => [
        presets,
        keepLast4,
        enhanceContrast,
        stripMetadata,
        outputFormat,
        script,
        pageFormat,
      ];
}

/// A single PII or facial region permanently masked on a document page.
class RedactedRegion extends Equatable {
  const RedactedRegion({
    required this.pageIndex,
    required this.category,
    required this.boundingBox,
    required this.maskedPreview,
    this.cornerPoints = const [],
  });

  final int pageIndex;
  final String category;
  final BoundingBoxRect boundingBox;
  final String maskedPreview;
  final List<CornerPoint> cornerPoints;

  Map<String, dynamic> toJson() {
    return {
      "page_index": pageIndex,
      "category": category,
      "bounding_box": boundingBox.toJson(),
      "corner_points": cornerPoints.map((p) => p.toJson()).toList(),
      "masked_preview": maskedPreview,
    };
  }

  @override
  List<Object?> get props => [
        pageIndex,
        category,
        boundingBox,
        maskedPreview,
        cornerPoints,
      ];
}

/// Summary metadata for a single page inside a generated searchable PDF.
class SearchablePdfPageSummary extends Equatable {
  const SearchablePdfPageSummary({
    required this.pageIndex,
    required this.width,
    required this.height,
    required this.ocrInferenceMs,
    required this.characterCount,
    required this.text,
  });

  final int pageIndex;
  final int width;
  final int height;
  final int ocrInferenceMs;
  final int characterCount;
  final String text;

  Map<String, dynamic> toJson() {
    return {
      "page_index": pageIndex,
      "width": width,
      "height": height,
      "ocr_inference_ms": ocrInferenceMs,
      "character_count": characterCount,
      "text": text,
    };
  }

  @override
  List<Object?> get props => [
        pageIndex,
        width,
        height,
        ocrInferenceMs,
        characterCount,
        text,
      ];
}

/// Result returned by [SearchablePdfEngine].
class SearchablePdfResult extends Equatable {
  const SearchablePdfResult({
    required this.pdfBytes,
    required this.pageCount,
    required this.byteLength,
    required this.targetSizeMet,
    required this.appliedJpegQuality,
    required this.appliedScaleFactor,
    required this.metadataStripped,
    required this.contrastEnhanced,
    required this.pageFormat,
    required this.processingMs,
    required this.fullText,
    required this.pages,
    this.targetMaxSizeMb,
    this.beforePreviewBase64,
    this.afterPreviewBase64,
  });

  final Uint8List pdfBytes;
  final int pageCount;
  final int byteLength;
  final double? targetMaxSizeMb;
  final bool targetSizeMet;
  final int appliedJpegQuality;
  final double appliedScaleFactor;
  final bool metadataStripped;
  final bool contrastEnhanced;
  final String pageFormat;
  final int processingMs;
  final String fullText;
  final List<SearchablePdfPageSummary> pages;
  final String? beforePreviewBase64;
  final String? afterPreviewBase64;

  Map<String, dynamic> toJson({bool includePdfBase64 = true}) {
    return {
      "status": "ok",
      "page_count": pageCount,
      "byte_length": byteLength,
      "target_max_size_mb": targetMaxSizeMb,
      "target_size_met": targetSizeMet,
      "applied_jpeg_quality": appliedJpegQuality,
      "applied_scale_factor": appliedScaleFactor,
      "metadata_stripped": metadataStripped,
      "contrast_enhanced": contrastEnhanced,
      "page_format": pageFormat,
      "processing_ms": processingMs,
      "text": fullText,
      "pages": pages.map((p) => p.toJson()).toList(),
      if (includePdfBase64) "pdf_base64": base64Encode(pdfBytes),
      if (beforePreviewBase64 != null)
        "before_image_base64": beforePreviewBase64,
      if (afterPreviewBase64 != null) "after_image_base64": afterPreviewBase64,
    };
  }

  @override
  List<Object?> get props => [
        pdfBytes,
        pageCount,
        byteLength,
        targetMaxSizeMb,
        targetSizeMet,
        appliedJpegQuality,
        appliedScaleFactor,
        metadataStripped,
        contrastEnhanced,
        pageFormat,
        processingMs,
        fullText,
        pages,
        beforePreviewBase64,
        afterPreviewBase64,
      ];
}

/// Result returned by [PiiRedactionEngine].
class RedactionResult extends Equatable {
  const RedactionResult({
    required this.outputBytes,
    required this.outputMimeType,
    required this.beforeImageBytes,
    required this.afterImageBytes,
    required this.pageCount,
    required this.redactedCount,
    required this.categoryCounts,
    required this.regions,
    required this.metadataStripped,
    required this.keepLast4,
    required this.contrastEnhanced,
    required this.processingMs,
    required this.sanitizedText,
    this.pdfBytes,
    this.imageWidth,
    this.imageHeight,
  });

  final Uint8List outputBytes;
  final String outputMimeType;
  final Uint8List? pdfBytes;
  final Uint8List beforeImageBytes;
  final Uint8List afterImageBytes;
  final int pageCount;
  final int redactedCount;
  final Map<String, int> categoryCounts;
  final List<RedactedRegion> regions;
  final bool metadataStripped;
  final bool keepLast4;
  final bool contrastEnhanced;
  final int processingMs;
  final String sanitizedText;
  final int? imageWidth;
  final int? imageHeight;

  Map<String, dynamic> toJson({bool includeBinaryBase64 = true}) {
    return {
      "status": "ok",
      "page_count": pageCount,
      "redacted_count": redactedCount,
      "category_counts": categoryCounts,
      "regions": regions.map((r) => r.toJson()).toList(),
      "metadata_stripped": metadataStripped,
      "keep_last_4": keepLast4,
      "contrast_enhanced": contrastEnhanced,
      "processing_ms": processingMs,
      "sanitized_text": sanitizedText,
      "image_width": imageWidth,
      "image_height": imageHeight,
      if (includeBinaryBase64)
        "before_image_base64": base64Encode(beforeImageBytes),
      if (includeBinaryBase64)
        "after_image_base64": base64Encode(afterImageBytes),
      if (includeBinaryBase64 && pdfBytes != null)
        "pdf_base64": base64Encode(pdfBytes!),
    };
  }

  @override
  List<Object?> get props => [
        outputBytes,
        outputMimeType,
        pdfBytes,
        beforeImageBytes,
        afterImageBytes,
        pageCount,
        redactedCount,
        categoryCounts,
        regions,
        metadataStripped,
        keepLast4,
        contrastEnhanced,
        processingMs,
        sanitizedText,
        imageWidth,
        imageHeight,
      ];
}

/// Categories of document pipeline jobs tracked in [DocumentPipelineCubit].
enum DocumentJobType {
  searchablePdf,
  piiRedaction,
  batchZip;

  String get label {
    switch (this) {
      case DocumentJobType.searchablePdf:
        return "Searchable PDF";
      case DocumentJobType.piiRedaction:
        return "PII Redact";
      case DocumentJobType.batchZip:
        return "Batch ZIP";
    }
  }
}

/// Immutable telemetry record emitted whenever a document pipeline job finishes.
class DocumentJobRecord extends Equatable {
  const DocumentJobRecord({
    required this.id,
    required this.timestamp,
    required this.type,
    required this.pageCount,
    required this.inputBytes,
    required this.outputBytes,
    required this.redactedCount,
    required this.metadataStripped,
    required this.processingMs,
    this.targetSizeMet = true,
  });

  final String id;
  final DateTime timestamp;
  final DocumentJobType type;
  final int pageCount;
  final int inputBytes;
  final int outputBytes;
  final int redactedCount;
  final bool metadataStripped;
  final int processingMs;
  final bool targetSizeMet;

  Map<String, dynamic> toJson() {
    return {
      "id": id,
      "timestamp": timestamp.toIso8601String(),
      "type": type.name,
      "page_count": pageCount,
      "input_bytes": inputBytes,
      "output_bytes": outputBytes,
      "redacted_count": redactedCount,
      "metadata_stripped": metadataStripped,
      "processing_ms": processingMs,
      "target_size_met": targetSizeMet,
    };
  }

  @override
  List<Object?> get props => [
        id,
        timestamp,
        type,
        pageCount,
        inputBytes,
        outputBytes,
        redactedCount,
        metadataStripped,
        processingMs,
        targetSizeMet,
      ];
}
