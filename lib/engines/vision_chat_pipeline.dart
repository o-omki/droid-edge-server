import "dart:convert";
import "dart:math" as math;

import "../models/geometry_models.dart";
import "../models/ocr_result.dart";
import "../models/openai_vision_models.dart";
import "document_input_loader.dart";
import "entity_extraction_engine.dart";
import "image_payload_processor.dart";
import "local_genai_engine.dart";
import "ocr_engine.dart";
import "pdf_rasterizer.dart";
import "spatial_table_reconstructor.dart";
import "structured_extraction_engine.dart";

/// Orchestrates OpenAI-compatible vision chat completions over the 3-tier
/// offline extraction pipeline.
///
/// Always executes Tier 1 (ML Kit OCR + 2D spatial table reconstruction +
/// entity & structured parsers) first as a deterministic baseline, then
/// optionally invokes Tier 3 / Tier 2 on-device GenAI with immediate fallback
/// to Tier 1 on unavailability, quota/busy errors, or invalid output.
class VisionChatPipeline {
  VisionChatPipeline({
    required this.ocrEngine,
    required this.pdfRasterizer,
    required this.entityExtractionEngine,
    required this.localGenAiEngine,
  });

  final OcrEngine ocrEngine;
  final PdfRasterizer pdfRasterizer;
  final EntityExtractionEngine entityExtractionEngine;
  final LocalGenAiEngine localGenAiEngine;

  int _completionCounter = 0;

  /// Runs local OCR / structured extraction for [request] and builds a
  /// compliant [ChatCompletionResponse].
  Future<ChatCompletionResponse> complete(ChatCompletionRequest request) async {
    final stopwatch = Stopwatch()..start();

    final ocr = await _extractCombinedOcr(request);
    final intent = ExtractionIntent.detect(
      prompt: request.prompt,
      responseFormatType: request.responseFormatType,
      requestedModel: request.model,
    );
    final forceJson = request.responseFormatType == "json_object" ||
        intent == ExtractionIntent.receipt;

    final String tier1Output = await _buildTier1Output(
      intent: intent,
      ocr: ocr,
      forceJson: forceJson,
      hasImages: request.imagePayloads.isNotEmpty,
      prompt: request.prompt,
    );

    final refinement = await localGenAiEngine.tryRefineExtraction(
      intent: intent,
      userPrompt: request.prompt,
      ocr: ocr,
      tier1Draft: tier1Output,
      forceJson: forceJson,
      requestedModel: request.model,
    );

    final finalContent = refinement.refinedText ?? tier1Output;
    stopwatch.stop();

    _completionCounter++;
    final nowSeconds = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final id = "chatcmpl-local-$nowSeconds-$_completionCounter";

    final promptTokens = _estimateTokens(request.prompt) +
        (request.imagePayloads.length * 256);
    final completionTokens = _estimateTokens(finalContent);

    return ChatCompletionResponse(
      id: id,
      created: nowSeconds,
      model: request.model.isEmpty ? "local-edge-vision" : request.model,
      content: finalContent,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      totalTokens: promptTokens + completionTokens,
      intent: intent,
      tierUsed: refinement.tierUsed,
      processingMs: stopwatch.elapsedMilliseconds,
      fallbackTriggered: refinement.fallbackTriggered,
    );
  }

  Future<OcrResult> _extractCombinedOcr(ChatCompletionRequest request) async {
    if (request.imagePayloads.isEmpty) {
      return _synthesiseOcrFromPrompt(request.prompt, script: request.script);
    }

    final pageBytes = await DocumentInputLoader.expandToPageBytes(
      request.imagePayloads,
      pdfRasterizer: pdfRasterizer,
    );

    final pageResults = <OcrResult>[];
    for (final bytes in pageBytes) {
      final staged = await ImagePayloadProcessor.prepareFromBytes(bytes);
      try {
        final result = await ocrEngine.processImage(
          staged,
          script: request.script,
        );
        pageResults.add(result);
      } finally {
        await staged.cleanup();
      }
    }

    if (pageResults.length == 1) {
      return pageResults.first;
    }

    return _mergePageOcrResults(pageResults, script: request.script);
  }

  Future<String> _buildTier1Output({
    required ExtractionIntent intent,
    required OcrResult ocr,
    required bool forceJson,
    required bool hasImages,
    required String prompt,
  }) async {
    switch (intent) {
      case ExtractionIntent.table:
        final table = SpatialTableReconstructor.reconstruct(ocr);
        if (forceJson) {
          return const JsonEncoder.withIndent("  ").convert(table.toJson());
        }
        return table.markdown;

      case ExtractionIntent.receipt:
        final entities = await entityExtractionEngine.extractEntities(ocr.text);
        final receipt = StructuredExtractionEngine.extractReceiptOrBill(
          ocr,
          entities,
          tierUsed: AiTier.tier1Deterministic.id,
        );
        return const JsonEncoder.withIndent("  ").convert(receipt.toJson());

      case ExtractionIntent.vcard:
        final entities = await entityExtractionEngine.extractEntities(ocr.text);
        final vcard = StructuredExtractionEngine.extractBusinessCard(
          ocr,
          entities,
        );
        if (forceJson) {
          return const JsonEncoder.withIndent("  ").convert(vcard.toJson());
        }
        return vcard.vcardText;

      case ExtractionIntent.ocr:
        final cleanText = ocr.text.trim();
        if (!hasImages && cleanText.split("\n").length <= 1) {
          final fallbackMsg =
              "Droid Edge Vision Server (Tier 1) is active and ready. "
              "Include an image_url (base64 data URI) to run offline OCR or "
              "structured extraction.";
          if (forceJson) {
            return const JsonEncoder.withIndent("  ").convert({
              "status": "ready",
              "message": fallbackMsg,
              "prompt": prompt.trim(),
            });
          }
          return fallbackMsg;
        }
        if (forceJson) {
          return const JsonEncoder.withIndent("  ").convert({
            "text": cleanText,
            "script": ocr.script,
            "detected_languages": ocr.detectedLanguages,
            "blocks": ocr.blocks.map((b) => b.toJson()).toList(),
          });
        }
        return cleanText;
    }
  }

  static OcrResult _synthesiseOcrFromPrompt(
    String prompt, {
    required OcrScript script,
  }) {
    final lines = prompt
        .split(RegExp(r"\r?\n"))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    final ocrLines = <OcrTextLine>[];
    for (var i = 0; i < lines.length; i++) {
      final top = (i * 28).toDouble();
      ocrLines.add(
        OcrTextLine(
          text: lines[i],
          boundingBox: BoundingBoxRect(
            left: 16,
            top: top,
            right: 400,
            bottom: top + 20,
          ),
        ),
      );
    }

    return OcrResult(
      text: lines.join("\n"),
      script: script.name,
      blocks: ocrLines.isEmpty
          ? const []
          : [
              OcrTextBlock(
                text: lines.join("\n"),
                lines: ocrLines,
              ),
            ],
      detectedLanguages: const ["en"],
      inferenceMs: 0,
    );
  }

  static OcrResult _mergePageOcrResults(
    List<OcrResult> pages, {
    required OcrScript script,
  }) {
    final combinedText = pages
        .map((p) => p.text.trim())
        .where((t) => t.isNotEmpty)
        .join("\n\n");
    final combinedBlocks = <OcrTextBlock>[];
    final combinedLanguages = <String>{};
    var totalInferenceMs = 0;
    var yOffset = 0.0;
    int? maxWidth;

    for (final page in pages) {
      totalInferenceMs += page.inferenceMs;
      combinedLanguages.addAll(page.detectedLanguages);
      if (page.imageWidth != null) {
        maxWidth = maxWidth == null
            ? page.imageWidth
            : math.max(maxWidth, page.imageWidth!);
      }

      for (final block in page.blocks) {
        combinedBlocks.add(_offsetBlock(block, yOffset));
      }
      yOffset += (page.imageHeight ?? 1000).toDouble() + 24.0;
    }

    return OcrResult(
      text: combinedText,
      script: script.name,
      blocks: combinedBlocks,
      detectedLanguages: combinedLanguages.toList(),
      inferenceMs: totalInferenceMs,
      imageWidth: maxWidth,
      imageHeight: yOffset.round(),
    );
  }

  static OcrTextBlock _offsetBlock(OcrTextBlock block, double yOffset) {
    return OcrTextBlock(
      text: block.text,
      boundingBox: _offsetRect(block.boundingBox, yOffset),
      cornerPoints: block.cornerPoints,
      recognizedLanguages: block.recognizedLanguages,
      lines: block.lines.map((line) {
        return OcrTextLine(
          text: line.text,
          boundingBox: _offsetRect(line.boundingBox, yOffset),
          cornerPoints: line.cornerPoints,
          recognizedLanguages: line.recognizedLanguages,
          confidence: line.confidence,
          elements: line.elements.map((elem) {
            return OcrTextElement(
              text: elem.text,
              boundingBox: _offsetRect(elem.boundingBox, yOffset),
              cornerPoints: elem.cornerPoints,
              recognizedLanguages: elem.recognizedLanguages,
              confidence: elem.confidence,
            );
          }).toList(),
        );
      }).toList(),
    );
  }

  static BoundingBoxRect? _offsetRect(BoundingBoxRect? rect, double yOffset) {
    if (rect == null || yOffset == 0.0) return rect;
    return BoundingBoxRect(
      left: rect.left,
      top: rect.top + yOffset,
      right: rect.right,
      bottom: rect.bottom + yOffset,
    );
  }

  static int _estimateTokens(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return 0;
    return math.max(1, (trimmed.length / 4).ceil());
  }
}
