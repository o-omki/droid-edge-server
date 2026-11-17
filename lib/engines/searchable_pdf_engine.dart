import "dart:convert";
import "dart:isolate";
import "dart:typed_data";

import "package:image/image.dart" as img;
import "package:pdf/pdf.dart";

import "../models/document_pipeline_models.dart";
import "../models/ocr_result.dart";
import "document_image_utils.dart";
import "document_input_loader.dart";
import "image_payload_processor.dart";
import "ocr_engine.dart";
import "pdf_rasterizer.dart";

class _StagedPdfPageInput {
  const _StagedPdfPageInput({
    required this.pageIndex,
    required this.workingImageBytes,
    required this.width,
    required this.height,
    required this.ocrResult,
  });

  final int pageIndex;
  final Uint8List workingImageBytes;
  final int width;
  final int height;
  final OcrResult ocrResult;
}

class _CompressionStep {
  const _CompressionStep({
    required this.scaleFactor,
    required this.jpegQuality,
  });

  final double scaleFactor;
  final int jpegQuality;
}

class _BuiltPdfOutput {
  const _BuiltPdfOutput({
    required this.pdfBytes,
    required this.appliedJpegQuality,
    required this.appliedScaleFactor,
    required this.targetSizeMet,
  });

  final Uint8List pdfBytes;
  final int appliedJpegQuality;
  final double appliedScaleFactor;
  final bool targetSizeMet;
}

/// Builds searchable "sandwich" PDF documents from single or multiple images
/// and scanned PDFs with page normalisation, contrast cleanup, invisible OCR
/// text alignment, metadata stripping, and bounded target file-size
/// compression.
class SearchablePdfEngine {
  SearchablePdfEngine({
    required this.ocrEngine,
    required this.pdfRasterizer,
  });

  final OcrEngine ocrEngine;
  final PdfRasterizer pdfRasterizer;

  /// Generates a searchable PDF from [rawInputs] using [options].
  Future<SearchablePdfResult> generateFromPayloads(
    List<Uint8List> rawInputs, {
    SearchablePdfOptions options = const SearchablePdfOptions(),
  }) async {
    if (options.maxSizeMb != null && options.maxSizeMb! <= 0) {
      throw const FormatException("max_size_mb must be greater than zero.");
    }

    final totalStopwatch = Stopwatch()..start();
    final pageBytesList = await DocumentInputLoader.expandToPageBytes(
      rawInputs,
      pdfRasterizer: pdfRasterizer,
    );

    final stagedPages = <_StagedPdfPageInput>[];
    final summaries = <SearchablePdfPageSummary>[];
    final textBuffer = StringBuffer();
    String? beforePreviewBase64;
    String? afterPreviewBase64;

    // Process each page sequentially inside isolates so only one decoded
    // page raster is resident in RAM at any time.
    for (var i = 0; i < pageBytesList.length; i++) {
      final rawPageBytes = pageBytesList[i];
      final capturePreview = options.includePreviews && i == 0;

      final preprocessed = await Isolate.run(
        () => DocumentImageUtils.preprocessPage(
          rawPageBytes,
          enhanceContrast: options.enhanceContrast,
          contrast: options.contrast,
          brightness: options.brightness,
          captureOriginalPreview: capturePreview,
        ),
      );

      if (capturePreview) {
        if (preprocessed.originalPreviewBytes != null) {
          beforePreviewBase64 =
              base64Encode(preprocessed.originalPreviewBytes!);
        }
        afterPreviewBase64 = base64Encode(preprocessed.workingImageBytes);
      }

      final payload = await ImagePayloadProcessor.prepareFromBytes(
        preprocessed.workingImageBytes,
      );
      final OcrResult ocr;
      try {
        ocr = await ocrEngine.processImage(payload, script: options.script);
      } finally {
        await payload.cleanup();
      }

      if (ocr.text.trim().isNotEmpty) {
        if (textBuffer.isNotEmpty) {
          textBuffer.writeln();
          textBuffer.writeln();
        }
        textBuffer.write(ocr.text.trim());
      }

      summaries.add(
        SearchablePdfPageSummary(
          pageIndex: i,
          width: preprocessed.width,
          height: preprocessed.height,
          ocrInferenceMs: ocr.inferenceMs,
          characterCount: ocr.text.length,
          text: ocr.text,
        ),
      );

      stagedPages.add(
        _StagedPdfPageInput(
          pageIndex: i,
          workingImageBytes: preprocessed.workingImageBytes,
          width: preprocessed.width,
          height: preprocessed.height,
          ocrResult: ocr,
        ),
      );
    }

    final targetMaxBytes = options.maxSizeMb != null
        ? (options.maxSizeMb! * 1024 * 1024).round()
        : null;

    final built = await Isolate.run(
      () => _buildSandwichPdfInIsolate(
        pages: stagedPages,
        pageFormat: options.pageFormat,
        stripMetadata: options.stripMetadata,
        targetMaxBytes: targetMaxBytes,
      ),
    );

    totalStopwatch.stop();

    return SearchablePdfResult(
      pdfBytes: built.pdfBytes,
      pageCount: stagedPages.length,
      byteLength: built.pdfBytes.length,
      targetMaxSizeMb: options.maxSizeMb,
      targetSizeMet: built.targetSizeMet,
      appliedJpegQuality: built.appliedJpegQuality,
      appliedScaleFactor: built.appliedScaleFactor,
      metadataStripped: options.stripMetadata,
      contrastEnhanced: options.enhanceContrast,
      pageFormat: options.pageFormat.name,
      processingMs: totalStopwatch.elapsedMilliseconds,
      fullText: textBuffer.toString(),
      pages: summaries,
      beforePreviewBase64: beforePreviewBase64,
      afterPreviewBase64: afterPreviewBase64,
    );
  }

  static Future<_BuiltPdfOutput> _buildSandwichPdfInIsolate({
    required List<_StagedPdfPageInput> pages,
    required PageNormalizationFormat pageFormat,
    required bool stripMetadata,
    required int? targetMaxBytes,
  }) async {
    final steps = targetMaxBytes == null
        ? const [
            _CompressionStep(scaleFactor: 1.0, jpegQuality: 84),
          ]
        : const [
            _CompressionStep(scaleFactor: 1.0, jpegQuality: 82),
            _CompressionStep(scaleFactor: 1.0, jpegQuality: 68),
            _CompressionStep(scaleFactor: 0.85, jpegQuality: 58),
            _CompressionStep(scaleFactor: 0.72, jpegQuality: 48),
            _CompressionStep(scaleFactor: 0.58, jpegQuality: 38),
            _CompressionStep(scaleFactor: 0.45, jpegQuality: 30),
            _CompressionStep(scaleFactor: 0.32, jpegQuality: 22),
            _CompressionStep(scaleFactor: 0.22, jpegQuality: 16),
          ];

    _BuiltPdfOutput? bestAttempt;

    for (final step in steps) {
      final doc = PdfDocument(compress: true);
      if (!stripMetadata) {
        PdfInfo(doc, creator: "Droid Edge Server", producer: "Droid Edge Server");
      }
      final font = PdfFont.helvetica(doc);

      for (final pageInput in pages) {
        final decoded = img.decodeImage(pageInput.workingImageBytes);
        if (decoded == null) {
          throw const ImagePayloadException(
            "Unable to decode staged page image during PDF assembly.",
          );
        }

        final jpegBytes = DocumentImageUtils.encodeCleanJpeg(
          decoded,
          quality: step.jpegQuality,
          scaleFactor: step.scaleFactor,
        );

        final resolvedFormat = DocumentImageUtils.resolvePdfPageFormat(
          pageFormat,
          pageInput.width,
          pageInput.height,
        );
        final page = PdfPage(doc, pageFormat: resolvedFormat);
        final graphics = page.getGraphics();
        final placement = DocumentImageUtils.computePagePlacement(
          resolvedFormat,
          pageInput.width,
          pageInput.height,
        );

        final pdfImage = PdfImage.jpeg(doc, image: jpegBytes);
        graphics.drawImage(
          pdfImage,
          placement.drawX,
          placement.drawY,
          placement.drawWidth,
          placement.drawHeight,
        );

        DocumentImageUtils.drawInvisibleOcrTextLayer(
          graphics: graphics,
          font: font,
          ocr: pageInput.ocrResult,
          imgWidth: pageInput.width,
          imgHeight: pageInput.height,
          drawX: placement.drawX,
          drawY: placement.drawY,
          drawWidth: placement.drawWidth,
          drawHeight: placement.drawHeight,
        );
      }

      final stream = PdfStream();
      await doc.write(stream);
      final pdfBytes = stream.output();
      final met = targetMaxBytes == null || pdfBytes.length <= targetMaxBytes;

      bestAttempt = _BuiltPdfOutput(
        pdfBytes: pdfBytes,
        appliedJpegQuality: step.jpegQuality,
        appliedScaleFactor: step.scaleFactor,
        targetSizeMet: met,
      );

      if (met) {
        return bestAttempt;
      }
    }

    return bestAttempt!;
  }
}
