import "dart:convert";
import "dart:typed_data";

import "package:shelf/shelf.dart";
import "package:shelf_multipart/shelf_multipart.dart";
import "package:shelf_router/shelf_router.dart";

import "../../engines/batch_zip_engine.dart";
import "../../engines/image_payload_processor.dart";
import "../../engines/pii_redaction_engine.dart";
import "../../engines/searchable_pdf_engine.dart";
import "../../models/document_pipeline_models.dart";
import "../../models/ocr_result.dart";

class _UploadedDocFile {
  const _UploadedDocFile({
    required this.name,
    required this.bytes,
  });

  final String name;
  final Uint8List bytes;
}

class _ParsedDocumentRequest {
  const _ParsedDocumentRequest({
    required this.files,
    required this.params,
  });

  final List<_UploadedDocFile> files;
  final Map<String, dynamic> params;

  int get totalInputBytes =>
      files.fold<int>(0, (sum, item) => sum + item.bytes.length);
}

/// HTTP route handler for Phase 5 document pipeline endpoints:
/// - `POST /v1/doc/searchable-pdf`
/// - `POST /v1/doc/redact`
/// - `POST /v1/doc/batch-zip`
class DocumentRoutes {
  DocumentRoutes({
    required this.searchablePdfEngine,
    required this.piiRedactionEngine,
    this.onJobCompleted,
  });

  final SearchablePdfEngine searchablePdfEngine;
  final PiiRedactionEngine piiRedactionEngine;
  final void Function(DocumentJobRecord job)? onJobCompleted;

  int _jobCounter = 0;

  Router get router {
    final router = Router();
    router.post("/v1/doc/searchable-pdf", _handleSearchablePdf);
    router.post("/v1/doc/redact", _handleRedact);
    router.post("/v1/doc/batch-zip", _handleBatchZip);
    return router;
  }

  Future<Response> _handleSearchablePdf(Request request) async {
    try {
      final parsed = await _parseRequest(request);
      final params = parsed.params;

      final pageFormat = PageNormalizationFormat.fromName(
        _stringParam(params, "page_format"),
        fallback: PageNormalizationFormat.a4,
      );
      final maxSizeMb = _optionalPositiveDouble(params, "max_size_mb");
      final enhance = _boolParam(
        params,
        "enhance",
        altKey: "enhance_contrast",
        fallback: true,
      );
      final contrast = _doubleParam(params, "contrast", fallback: 1.18);
      final brightness = _doubleParam(params, "brightness", fallback: 1.02);
      final stripMetadata = _boolParam(
        params,
        "strip_metadata",
        fallback: true,
      );
      final script = OcrScript.fromName(_stringParam(params, "script"));
      final responseFormat =
          (_stringParam(params, "response_format") ??
                  _stringParam(params, "format") ??
                  "pdf")
              .toLowerCase();
      if (responseFormat != "pdf" && responseFormat != "json") {
        throw FormatException(
          "Unsupported response_format \"$responseFormat\". Supported values: "
          "pdf, json.",
        );
      }

      final options = SearchablePdfOptions(
        pageFormat: pageFormat,
        enhanceContrast: enhance,
        contrast: contrast,
        brightness: brightness,
        maxSizeMb: maxSizeMb,
        script: script,
        stripMetadata: stripMetadata,
        includePreviews: responseFormat == "json",
      );

      final result = await searchablePdfEngine.generateFromPayloads(
        parsed.files.map((f) => f.bytes).toList(),
        options: options,
      );

      _emitJob(
        DocumentJobRecord(
          id: _nextJobId(),
          timestamp: DateTime.now(),
          type: DocumentJobType.searchablePdf,
          pageCount: result.pageCount,
          inputBytes: parsed.totalInputBytes,
          outputBytes: result.byteLength,
          redactedCount: 0,
          metadataStripped: result.metadataStripped,
          processingMs: result.processingMs,
          targetSizeMet: result.targetSizeMet,
        ),
      );

      if (responseFormat == "json") {
        return Response.ok(
          jsonEncode(result.toJson(includePdfBase64: true)),
          headers: const {"content-type": "application/json; charset=utf-8"},
        );
      }

      return Response.ok(
        result.pdfBytes,
        headers: {
          "content-type": "application/pdf",
          "content-disposition":
              "attachment; filename=\"searchable_document.pdf\"",
          "x-page-count": "${result.pageCount}",
          "x-file-size-bytes": "${result.byteLength}",
          "x-target-size-met": "${result.targetSizeMet}",
          "x-applied-quality": "${result.appliedJpegQuality}",
          "x-applied-scale": "${result.appliedScaleFactor}",
          "x-metadata-stripped": "${result.metadataStripped}",
          "x-processing-ms": "${result.processingMs}",
        },
      );
    } on ImagePayloadException catch (error) {
      return _badRequest(error.message);
    } on FormatException catch (error) {
      return _badRequest(error.message);
    }
  }

  Future<Response> _handleRedact(Request request) async {
    try {
      final parsed = await _parseRequest(request);
      final params = parsed.params;

      final rawPresets = params["presets"];
      final String? presetsStr;
      if (rawPresets is List) {
        presetsStr = rawPresets.map((e) => e.toString()).join(",");
      } else {
        presetsStr = _stringParam(params, "presets");
      }

      final presets = RedactionPreset.parsePresets(presetsStr);
      final keepLast4 = _boolParam(params, "keep_last_4", fallback: false);
      final enhance = _boolParam(
        params,
        "enhance",
        altKey: "enhance_contrast",
        fallback: false,
      );
      final stripMetadata = _boolParam(
        params,
        "strip_metadata",
        fallback: true,
      );
      final script = OcrScript.fromName(_stringParam(params, "script"));
      final pageFormat = PageNormalizationFormat.fromName(
        _stringParam(params, "page_format"),
        fallback: PageNormalizationFormat.original,
      );
      final outputFormat = RedactionOutputFormat.fromName(
        _stringParam(params, "output_format") ??
            _stringParam(params, "response_format") ??
            _stringParam(params, "format"),
      );

      final result = await piiRedactionEngine.redactPayloads(
        parsed.files.map((f) => f.bytes).toList(),
        options: RedactionOptions(
          presets: presets,
          keepLast4: keepLast4,
          enhanceContrast: enhance,
          stripMetadata: stripMetadata,
          outputFormat: outputFormat,
          script: script,
          pageFormat: pageFormat,
        ),
      );

      _emitJob(
        DocumentJobRecord(
          id: _nextJobId(),
          timestamp: DateTime.now(),
          type: DocumentJobType.piiRedaction,
          pageCount: result.pageCount,
          inputBytes: parsed.totalInputBytes,
          outputBytes: result.outputBytes.length,
          redactedCount: result.redactedCount,
          metadataStripped: result.metadataStripped,
          processingMs: result.processingMs,
          targetSizeMet: true,
        ),
      );

      if (outputFormat == RedactionOutputFormat.json) {
        return Response.ok(
          jsonEncode(result.toJson(includeBinaryBase64: true)),
          headers: const {"content-type": "application/json; charset=utf-8"},
        );
      }

      final filename = outputFormat == RedactionOutputFormat.pdf
          ? "redacted_document.pdf"
          : "redacted_document.png";

      return Response.ok(
        result.outputBytes,
        headers: {
          "content-type": result.outputMimeType,
          "content-disposition": "attachment; filename=\"$filename\"",
          "x-page-count": "${result.pageCount}",
          "x-redacted-count": "${result.redactedCount}",
          "x-metadata-stripped": "${result.metadataStripped}",
          "x-keep-last-4": "${result.keepLast4}",
          "x-processing-ms": "${result.processingMs}",
        },
      );
    } on ImagePayloadException catch (error) {
      return _badRequest(error.message);
    } on FormatException catch (error) {
      return _badRequest(error.message);
    }
  }

  Future<Response> _handleBatchZip(Request request) async {
    try {
      final stopwatch = Stopwatch()..start();
      final parsed = await _parseRequest(request);
      final params = parsed.params;

      final rawMode =
          (_stringParam(params, "mode") ??
                  _stringParam(params, "operation") ??
                  "searchable-pdf")
              .toLowerCase();
      final isRedact = rawMode == "redact" || rawMode == "pii-redact";
      final isSearchablePdf =
          rawMode == "searchable-pdf" || rawMode == "pdf" || rawMode == "ocr-pdf";
      if (!isRedact && !isSearchablePdf) {
        throw FormatException(
          "Unsupported batch mode \"$rawMode\". Supported values: "
          "searchable-pdf, redact.",
        );
      }

      final script = OcrScript.fromName(_stringParam(params, "script"));
      final pageFormat = PageNormalizationFormat.fromName(
        _stringParam(params, "page_format"),
        fallback: isRedact
            ? PageNormalizationFormat.original
            : PageNormalizationFormat.a4,
      );
      final maxSizeMb = _optionalPositiveDouble(params, "max_size_mb");
      final enhance = _boolParam(
        params,
        "enhance",
        altKey: "enhance_contrast",
        fallback: !isRedact,
      );
      final stripMetadata = _boolParam(
        params,
        "strip_metadata",
        fallback: true,
      );

      final rawPresets = params["presets"];
      final String? presetsStr = rawPresets is List
          ? rawPresets.map((e) => e.toString()).join(",")
          : _stringParam(params, "presets");
      final presets = RedactionPreset.parsePresets(presetsStr);
      final keepLast4 = _boolParam(params, "keep_last_4", fallback: false);
      final redactFormatRaw =
          (_stringParam(params, "output_format") ?? "image").toLowerCase();
      final redactOutputFormat = redactFormatRaw == "pdf"
          ? RedactionOutputFormat.pdf
          : RedactionOutputFormat.image;

      final entries = <BatchArchiveEntry>[];
      var totalPages = 0;
      var totalRedacted = 0;

      // Process each queued file strictly sequentially to keep mobile memory bounded.
      for (var i = 0; i < parsed.files.length; i++) {
        final file = parsed.files[i];
        final stem = _fileStem(file.name, fallbackIndex: i + 1);

        if (isRedact) {
          final result = await piiRedactionEngine.redactPayloads(
            [file.bytes],
            options: RedactionOptions(
              presets: presets,
              keepLast4: keepLast4,
              enhanceContrast: enhance,
              stripMetadata: stripMetadata,
              outputFormat: redactOutputFormat,
              script: script,
              pageFormat: pageFormat,
            ),
          );
          totalPages += result.pageCount;
          totalRedacted += result.redactedCount;
          final ext =
              redactOutputFormat == RedactionOutputFormat.pdf ? "pdf" : "png";
          entries.add(
            BatchArchiveEntry(
              filename: "${stem}_redacted.$ext",
              bytes: result.outputBytes,
              metadata: {
                "operation": "redact",
                "page_count": result.pageCount,
                "redacted_count": result.redactedCount,
                "category_counts": result.categoryCounts,
                "metadata_stripped": result.metadataStripped,
                "keep_last_4": result.keepLast4,
              },
            ),
          );
        } else {
          final result = await searchablePdfEngine.generateFromPayloads(
            [file.bytes],
            options: SearchablePdfOptions(
              pageFormat: pageFormat,
              enhanceContrast: enhance,
              maxSizeMb: maxSizeMb,
              script: script,
              stripMetadata: stripMetadata,
              includePreviews: false,
            ),
          );
          totalPages += result.pageCount;
          entries.add(
            BatchArchiveEntry(
              filename: "${stem}_searchable.pdf",
              bytes: result.pdfBytes,
              metadata: {
                "operation": "searchable-pdf",
                "page_count": result.pageCount,
                "target_size_met": result.targetSizeMet,
                "applied_jpeg_quality": result.appliedJpegQuality,
                "metadata_stripped": result.metadataStripped,
              },
            ),
          );
        }
      }

      final zipBytes = await BatchZipEngine.buildZip(
        entries,
        manifestSummary: {
          "operation": isRedact ? "redact" : "searchable-pdf",
          "total_pages": totalPages,
          "total_redacted": totalRedacted,
          "metadata_stripped": stripMetadata,
        },
      );

      stopwatch.stop();

      _emitJob(
        DocumentJobRecord(
          id: _nextJobId(),
          timestamp: DateTime.now(),
          type: DocumentJobType.batchZip,
          pageCount: totalPages,
          inputBytes: parsed.totalInputBytes,
          outputBytes: zipBytes.length,
          redactedCount: totalRedacted,
          metadataStripped: stripMetadata,
          processingMs: stopwatch.elapsedMilliseconds,
          targetSizeMet: true,
        ),
      );

      return Response.ok(
        zipBytes,
        headers: {
          "content-type": "application/zip",
          "content-disposition":
              "attachment; filename=\"droid_edge_batch.zip\"",
          "x-batch-count": "${entries.length}",
          "x-page-count": "$totalPages",
          "x-redacted-count": "$totalRedacted",
          "x-metadata-stripped": "$stripMetadata",
          "x-processing-ms": "${stopwatch.elapsedMilliseconds}",
        },
      );
    } on ImagePayloadException catch (error) {
      return _badRequest(error.message);
    } on FormatException catch (error) {
      return _badRequest(error.message);
    }
  }

  Future<_ParsedDocumentRequest> _parseRequest(Request request) async {
    final mergedParams = <String, dynamic>{
      ...request.url.queryParameters,
    };

    final formRequest = request.formData();
    if (formRequest != null) {
      final files = <_UploadedDocFile>[];
      await for (final field in formRequest.formData) {
        final nameLower = field.name.toLowerCase();
        final partContentType =
            (field.part.headers["content-type"] ?? "").toLowerCase();
        final isFileField = field.filename != null ||
            nameLower == "file" ||
            nameLower == "files" ||
            nameLower == "image" ||
            nameLower == "images" ||
            nameLower == "pdf" ||
            nameLower == "document" ||
            partContentType.startsWith("image/") ||
            partContentType == "application/pdf";

        if (isFileField) {
          final bytes = await field.part.readBytes();
          if (bytes.isNotEmpty) {
            files.add(
              _UploadedDocFile(
                name: field.filename ?? "document_${files.length + 1}",
                bytes: bytes,
              ),
            );
          }
        } else {
          final value = (await field.part.readString()).trim();
          if (value.isNotEmpty) {
            mergedParams[nameLower] = value;
          }
        }
      }

      if (files.isEmpty) {
        throw const ImagePayloadException(
          "No image or PDF files found in multipart upload.",
        );
      }
      return _ParsedDocumentRequest(files: files, params: mergedParams);
    }

    final contentType =
        (request.headers["content-type"] ?? "").toLowerCase();
    if (contentType.contains("application/json")) {
      final rawText = await request.readAsString();
      return _parseJsonBody(rawText, queryParams: mergedParams);
    }

    final rawBytes = await _readAllBytes(request);
    if (rawBytes.isEmpty) {
      throw const ImagePayloadException(
        "Request body is empty. Upload an image or PDF via multipart "
        "form-data, JSON base64 payload, or raw binary bytes.",
      );
    }

    if (contentType.isEmpty && _looksLikeJsonObject(rawBytes)) {
      final text = utf8.decode(rawBytes, allowMalformed: false);
      return _parseJsonBody(text, queryParams: mergedParams);
    }

    return _ParsedDocumentRequest(
      files: [_UploadedDocFile(name: "document", bytes: rawBytes)],
      params: mergedParams,
    );
  }

  _ParsedDocumentRequest _parseJsonBody(
    String rawText, {
    required Map<String, dynamic> queryParams,
  }) {
    if (rawText.trim().isEmpty) {
      throw const ImagePayloadException("JSON request body is empty.");
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(rawText);
    } on FormatException {
      throw const ImagePayloadException("Malformed JSON request body.");
    }

    if (decoded is! Map<String, dynamic>) {
      throw const ImagePayloadException("JSON body must be an object.");
    }

    final merged = <String, dynamic>{...queryParams};
    for (final entry in decoded.entries) {
      final key = entry.key.toLowerCase();
      if (key == "image" ||
          key == "images" ||
          key == "pdf" ||
          key == "pdf_base64" ||
          key == "image_base64" ||
          key == "data" ||
          key == "files") {
        continue;
      }
      merged[key] = entry.value;
    }

    final files = <_UploadedDocFile>[];
    final filesArray = decoded["files"] ?? decoded["images"];
    if (filesArray is List) {
      for (var i = 0; i < filesArray.length; i++) {
        final item = filesArray[i];
        if (item is String && item.trim().isNotEmpty) {
          files.add(
            _UploadedDocFile(
              name: "document_${i + 1}",
              bytes: _decodeBase64Payload(item),
            ),
          );
        } else if (item is Map<String, dynamic>) {
          final rawData = item["data"] ??
              item["base64"] ??
              item["image"] ??
              item["pdf"];
          if (rawData is String && rawData.trim().isNotEmpty) {
            final name = item["name"]?.toString() ?? "document_${i + 1}";
            files.add(
              _UploadedDocFile(
                name: name,
                bytes: _decodeBase64Payload(rawData),
              ),
            );
          }
        }
      }
    }

    final singlePayload = decoded["image"] ??
        decoded["image_base64"] ??
        decoded["pdf"] ??
        decoded["pdf_base64"] ??
        decoded["data"];
    if (singlePayload is String && singlePayload.trim().isNotEmpty) {
      files.add(
        _UploadedDocFile(
          name: decoded["filename"]?.toString() ?? "document",
          bytes: _decodeBase64Payload(singlePayload),
        ),
      );
    }

    if (files.isEmpty) {
      throw const ImagePayloadException(
        "JSON payload must include a non-empty \"image\", \"pdf\", \"files\", "
        "or \"images\" base64 entry.",
      );
    }

    return _ParsedDocumentRequest(files: files, params: merged);
  }

  static Uint8List _decodeBase64Payload(String raw) {
    final trimmed = raw.trim();
    var encoded = trimmed;
    if (trimmed.startsWith("data:")) {
      final commaIdx = trimmed.indexOf(",");
      if (commaIdx == -1 || commaIdx == trimmed.length - 1) {
        throw const ImagePayloadException(
          "Malformed data URI in base64 document payload.",
        );
      }
      encoded = trimmed.substring(commaIdx + 1);
    }
    try {
      return Uint8List.fromList(
        base64Decode(encoded.replaceAll(RegExp(r"\s+"), "")),
      );
    } on FormatException {
      throw const ImagePayloadException(
        "Invalid base64 encoding in document payload.",
      );
    }
  }

  static Future<Uint8List> _readAllBytes(Request request) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request.read()) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  static bool _looksLikeJsonObject(Uint8List bytes) {
    for (final byte in bytes) {
      if (byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D) {
        continue;
      }
      return byte == 0x7B;
    }
    return false;
  }

  static String? _stringParam(Map<String, dynamic> params, String key) {
    final val = params[key];
    if (val == null) return null;
    final text = val.toString().trim();
    return text.isEmpty ? null : text;
  }

  static bool _boolParam(
    Map<String, dynamic> params,
    String key, {
    String? altKey,
    required bool fallback,
  }) {
    final val = params[key] ?? (altKey != null ? params[altKey] : null);
    if (val == null) return fallback;
    if (val is bool) return val;
    final text = val.toString().trim().toLowerCase();
    if (text == "true" || text == "1" || text == "yes") return true;
    if (text == "false" || text == "0" || text == "no") return false;
    throw FormatException("Invalid boolean value \"$val\" for \"$key\".");
  }

  static double _doubleParam(
    Map<String, dynamic> params,
    String key, {
    required double fallback,
  }) {
    final val = params[key];
    if (val == null) return fallback;
    if (val is num) return val.toDouble();
    final parsed = double.tryParse(val.toString().trim());
    if (parsed == null) {
      throw FormatException("Invalid numeric value \"$val\" for \"$key\".");
    }
    return parsed;
  }

  static double? _optionalPositiveDouble(
    Map<String, dynamic> params,
    String key,
  ) {
    final val = params[key];
    if (val == null) return null;
    if (val is String && val.trim().isEmpty) return null;
    final parsed =
        val is num ? val.toDouble() : double.tryParse(val.toString().trim());
    if (parsed == null || parsed <= 0) {
      throw FormatException(
        "Parameter \"$key\" must be a positive number (received \"$val\").",
      );
    }
    return parsed;
  }

  static String _fileStem(String rawName, {required int fallbackIndex}) {
    final base = rawName.split(RegExp(r"[\\/]")).last.trim();
    final cleaned = base.replaceAll(RegExp(r"[^A-Za-z0-9._\-]"), "_");
    final dotIdx = cleaned.lastIndexOf(".");
    final stem = dotIdx > 0 ? cleaned.substring(0, dotIdx) : cleaned;
    if (stem.isEmpty || stem == "." || stem == "..") {
      return "document_$fallbackIndex";
    }
    return stem;
  }

  String _nextJobId() {
    _jobCounter++;
    return "${DateTime.now().microsecondsSinceEpoch}-$_jobCounter";
  }

  void _emitJob(DocumentJobRecord record) {
    onJobCompleted?.call(record);
  }

  static Response _badRequest(String message) {
    return Response.badRequest(
      body: jsonEncode({
        "error": "bad_request",
        "message": message,
      }),
      headers: const {"content-type": "application/json; charset=utf-8"},
    );
  }
}
