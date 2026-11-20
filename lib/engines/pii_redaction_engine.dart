import "dart:isolate";
import "dart:math" as math;
import "dart:typed_data";

import "package:image/image.dart" as img;
import "package:pdf/pdf.dart";

import "../models/document_pipeline_models.dart";
import "../models/geometry_models.dart";
import "../models/ocr_result.dart";
import "../models/openai_vision_models.dart";
import "document_image_utils.dart";
import "document_input_loader.dart";
import "entity_extraction_engine.dart";
import "face_detection_engine.dart";
import "image_payload_processor.dart";
import "ocr_engine.dart";
import "pdf_rasterizer.dart";

enum _FieldHeaderKind {
  id,
  address,
  name,
  dob,
  otherField,
}

class _IndexedLine {
  const _IndexedLine({
    required this.blockIndex,
    required this.lineIndex,
    required this.line,
    required this.text,
    required this.spans,
    required this.headerKind,
    required this.isStandaloneHeader,
  });

  final int blockIndex;
  final int lineIndex;
  final OcrTextLine line;
  final String text;
  final List<_ElementSpan> spans;
  final _FieldHeaderKind? headerKind;
  final bool isStandaloneHeader;
}

class _BurnRegionSpec {
  const _BurnRegionSpec({
    required this.region,
    required this.expandRightEdge,
  });

  final RedactedRegion region;
  final bool expandRightEdge;
}

class _ElementSpan {
  const _ElementSpan({
    required this.index,
    required this.start,
    required this.end,
    required this.element,
  });

  final int index;
  final int start;
  final int end;
  final OcrTextElement element;
}

class _PiiMatchCandidate {
  const _PiiMatchCandidate({
    required this.category,
    required this.start,
    required this.end,
    required this.matchedText,
    required this.supportsKeepLast4,
    this.maskPreviewOverride,
  });

  final String category;
  final int start;
  final int end;
  final String matchedText;
  final bool supportsKeepLast4;
  final String? maskPreviewOverride;
}

class _StagedSanitizedPage {
  const _StagedSanitizedPage({
    required this.pageIndex,
    required this.sanitizedPngBytes,
    required this.width,
    required this.height,
    required this.sanitizedOcr,
  });

  final int pageIndex;
  final Uint8List sanitizedPngBytes;
  final int width;
  final int height;
  final OcrResult sanitizedOcr;
}

/// Permanently redacts sensitive PII text (IDs/cards, contacts, addresses)
/// and detected faces from images or scanned PDFs, stripping embedded EXIF/GPS
/// and PDF metadata.
class PiiRedactionEngine {
  PiiRedactionEngine({
    required this.ocrEngine,
    required this.faceDetectionEngine,
    required this.pdfRasterizer,
    this.entityExtractionEngine,
  });

  final OcrEngine ocrEngine;
  final FaceDetectionEngine faceDetectionEngine;
  final PdfRasterizer pdfRasterizer;
  final EntityExtractionEngine? entityExtractionEngine;

  static final RegExp _emailRegex = RegExp(
    r"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b",
  );
  static final RegExp _upiRegex = RegExp(
    r"\b[A-Za-z0-9._\-]{2,256}@(?:okaxis|okhdfcbank|okicici|oksbi|ybl|ibl|axl|paytm|upi|apl|fbl|kotak|axisbank|hdfcbank|icici|sbi|pnb|boi|barodampay|idfcbank|indus|yesbank|federal|rbl|citi|hsbc|dbs|freecharge|mobikwik|airtel|jio|postbank|indianbank|canarabank|unionbank|waaxis|wahdfcbank|waicici|wasbi)\b",
    caseSensitive: false,
  );
  static final RegExp _groupedCardRegex = RegExp(
    r"(?<!\d)\d{4}[\s\-]\d{4}[\s\-]\d{4}[\s\-]\d{3,4}(?!\d)",
  );
  static final RegExp _compactCardRegex = RegExp(
    r"(?<!\d)(?:\d[\s\-]?){13,19}(?!\d)",
  );
  static final RegExp _ssnRegex = RegExp(r"(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)");
  static final RegExp _aadhaarRegex = RegExp(
    r"(?<!\d)\d{4}[\s\-]\d{4}[\s\-]\d{4}(?!\d)",
  );
  static final RegExp _panRegex = RegExp(r"\b[A-Z]{5}\s?\d{4}\s?[A-Z]\b");
  static final RegExp _gstinRegex = RegExp(
    r"\b\d{2}[A-Z]{5}\d{4}[A-Z][1-9A-Z]Z[0-9A-Z]\b",
  );
  static final RegExp _voterIdRegex = RegExp(r"\b[A-Z]{3}\d{7}\b");
  static final RegExp _indianDlRegex = RegExp(
    r"\b[A-Z]{2}[\s\-]?\d{2}[\s\-]?(?:19|20)\d{2}[\s\-]?\d{7}\b",
  );
  static final RegExp _indianPassportRegex = RegExp(
    r"\b[A-PR-WY][1-9]\d\s?\d{4}[1-9]\b",
  );
  static final RegExp _singaporeNricRegex = RegExp(
    r"\b[STFGM]\d{7}[A-Z]\b",
  );
  static final RegExp _ukNiRegex = RegExp(
    r"\b(?:QQ|[A-CEGHJ-PR-TW-Z]{2})\s?\d{2}\s?\d{2}\s?\d{2}\s?[A-D]\b",
  );
  static final RegExp _ukDlRegex = RegExp(
    r"\b[A-Z9]{5}\d{6}[A-Z9]{2}\d[A-Z]{2}\b",
  );
  static final RegExp _ifscRegex = RegExp(r"\b[A-Z]{4}0[A-Z0-9]{6}\b");
  static final RegExp _ibanRegex = RegExp(r"\b[A-Z]{2}\d{2}[A-Z0-9]{10,28}\b");
  static final RegExp _labeledIdRegex = RegExp(
    r"(?:\b(?:ID|ID\s*#|SSN|SIN|TIN|EIN|Tax\s*ID|Account|Acct|Acc|Card|Policy|License|Licence|DL|Passport|Member\s*ID|Customer\s*ID|Document|Doc|Dokumentennummer|Ausweisnummer|Zugangsnummer|National\s+Insurance|NRIC|FIN|Personalnummer|Aadhaar|Aadhar|UID|VID|PAN|GSTIN|GST|EPIC|Voter\s*ID|PRAN|UAN|IFSC|CIF|CKYC|ABHA|Ayushman)\b|(?:身份证号码|证件号码|आधार|पैन|पहचान))(?:\s*(?:No\.?|Num\.?|Number|संख्या|#))?(?:\s*/[^:\n]{1,24})?\s*[:#\-]?\s*(?=[A-Z0-9\-]*\d)([A-Z0-9][A-Z0-9\-]{4,24})",
    caseSensitive: false,
  );
  static final RegExp _indianMobileRegex = RegExp(
    r"(?<!\d)(?:\+91[\s\-.]?|91[\s\-.]|0)?[6-9]\d{4}[\s\-]?\d{5}(?!\d)",
  );
  static final RegExp _phoneRegex = RegExp(
    r"(?<!\d)(?:\+?\d{1,3}[\s\-.]?)?(?:\(\d{2,4}\)|\d{2,4})[\s\-.]\d{3,4}[\s\-.]\d{3,4}(?!\d)",
  );
  static final RegExp _intlPhoneRegex = RegExp(
    r"(?<!\d)\+\d[\d\s\-.]{7,15}\d(?!\d)",
  );
  static final RegExp _labeledPhoneRegex = RegExp(
    r"\b(?:Tel|Telephone|Phone|Mobile|Mob|Cell|Fax)\b\s*[:#\-]?\s*([+\d()\-\s.]{7,20}\d)",
    caseSensitive: false,
  );
  static final RegExp _labeledAddressRegex = RegExp(
    r"(?:\b(?:Address|Addr|Residence|Location|Anschrift|Adresse|Wohnort|Wohnsitz|Domicile|Indirizzo|Dirección|Direccion|Adres|Endereço|Endereco)\b|住所|地址|住址|पता)(?:\s*/[^:\-\n]{1,24})?\s*[:\-]\s*(.+)$",
    caseSensitive: false,
  );
  static final RegExp _streetAddressRegex = RegExp(
    r"\b(?:(?:BLK|Block)\s+)?\d{1,6}[A-Za-z]?\s+(?:[A-Za-z0-9.#\-]+\s+){1,5}(?:Street|St|Avenue|Ave|Road|Rd|Boulevard|Blvd|Lane|Ln|Drive|Dr|Court|Ct|Way|Parkway|Pkwy|Circle|Cir|Place|Pl|Terrace|Ter|Square|Sq|Crescent|Cres|Close|Gardens|Gdns|Grove|Walk|Row|Mews)\b\.?(?:[,\s]+[A-Za-z0-9\s,\-]{2,40})?",
    caseSensitive: false,
  );
  static final RegExp _europeanStreetAddressRegex = RegExp(
    r"(?:\b(?:\d{1,5}[A-Za-z]?\s+)?(?:[A-Za-zÀ-ÿ][A-Za-zÀ-ÿ0-9\-]{1,28}\s+){0,3}[A-Za-zÀ-ÿ][A-Za-zÀ-ÿ\-]{1,24}(?:strasse|straße|str\.|weg|platz|allee|ring|gasse|damm|ufer|chaussee|steig)\s+\d{1,5}[A-Za-z]?(?:[,\s]+(?:\d{4,5}\s+)?[A-Za-zÀ-ÿ0-9\s,\-]{2,40})?|\b\d{1,5}[A-Za-z]?\s+(?:[A-Za-zÀ-ÿ0-9\-]+\s+){0,3}[A-Za-zÀ-ÿ][A-Za-zÀ-ÿ\-]{1,24}(?:strasse|straße|str\.|weg|platz|allee|ring|gasse|damm|ufer|chaussee|steig)\b(?:[,\s]+(?:\d{4,5}\s+)?[A-Za-zÀ-ÿ0-9\s,\-]{2,40})?|\b\d{1,5}[A-Za-z]?\s+(?:Rue|Allée|Impasse|Chemin|Calle|Avenida|Avda\.|Paseo|Via|Viale|Piazza|Corso|Straat|Laan|Plein)\s+[A-Za-zÀ-ÿ0-9.'\-\s]{2,45}|\b(?:Rue|Allée|Impasse|Chemin|Calle|Avenida|Avda\.|Paseo|Via|Viale|Piazza|Corso|Straat|Laan|Plein)\s+(?:[A-Za-zÀ-ÿ0-9.'\-]+\s+){1,5}\d{1,5}[A-Za-z]?(?:[,\s]+(?:\d{4,5}\s+)?[A-Za-zÀ-ÿ0-9\s,\-]{2,40})?)",
    caseSensitive: false,
  );
  static final RegExp _ukPostcodeAddressRegex = RegExp(
    r"(?:[A-Za-z][A-Za-z.\-\s]{1,28}[,\s]+)?\b(?:GIR\s?0AA|[A-PR-UWYZ][A-HK-Y]?\d[A-Z\d]?\s?\d[ABD-HJLNP-UW-Z]{2})\b",
  );
  static final RegExp _euPostalCityRegex = RegExp(
    r"(?<![.\-/\d])\b\d{5}\s+[A-ZÀ-ÖØ-Þ][A-Za-zÀ-ÿ\-]{2,28}(?:\s+[A-ZÀ-ÖØ-Þ][A-Za-zÀ-ÿ\-]{2,20})?\b",
  );
  static final RegExp _singaporeAddressLineRegex = RegExp(
    r"(?:#\d{1,3}-\d{1,5}(?:[,\s]+[A-Za-z0-9\s,\-]{2,40})?|\bSINGAPORE\s+\d{6}\b|\bBLK\s+\d+[A-Z]?\s+[A-Za-z0-9\s,.\-#]{3,50})",
    caseSensitive: false,
  );
  static final RegExp _indianAddressLineRegex = RegExp(
    r"\b(?:Flat|H\.?\s*No|House\s*No|Plot\s*No|Door\s*No|Survey\s*No|Sy\.?\s*No|Ward|Sector|Phase|Block|Cross|Main|Stage|Marg|Nagar|Colony|Vihar|Puram|Layout|Enclave|Society|Apartments|CHS|Taluka|Tehsil|Dist\.?|District|[A-Za-z]+(?:nagar|puram|ganj|bagh))\b[A-Za-z0-9\s,./#\-]{2,80}",
    caseSensitive: false,
  );
  static final RegExp _postalAddressLineRegex = RegExp(
    r"(?:[A-Za-z.\s]+,\s*[A-Z]{2}\s+\d{5}(?:-\d{4})?|\b(?:PIN|ZIP|Postal(?:\s+Code)?)\s*[:#\-]?\s*[1-9]?\d{5}\b|[A-Za-z.\s]{3,28}\s*[,\-]\s*[1-9]\d{2}\s?\d{3}\b)",
    caseSensitive: false,
  );

  /// Redacts sensitive regions across [rawInputs] according to [options].
  Future<RedactionResult> redactPayloads(
    List<Uint8List> rawInputs, {
    RedactionOptions options = const RedactionOptions(),
  }) async {
    final stopwatch = Stopwatch()..start();
    final pageBytesList = await DocumentInputLoader.expandToPageBytes(
      rawInputs,
      pdfRasterizer: pdfRasterizer,
    );

    final allRegions = <RedactedRegion>[];
    final categoryCounts = <String, int>{
      "id": 0,
      "contact": 0,
      "address": 0,
      "face": 0,
    };
    final stagedSanitizedPages = <_StagedSanitizedPage>[];
    final sanitizedTextBuffer = StringBuffer();

    Uint8List? firstBeforeBytes;
    Uint8List? firstAfterBytes;
    int? firstPageWidth;
    int? firstPageHeight;

    for (var pageIndex = 0; pageIndex < pageBytesList.length; pageIndex++) {
      final rawPageBytes = pageBytesList[pageIndex];
      final preprocessed = await Isolate.run(
        () => DocumentImageUtils.preprocessPage(
          rawPageBytes,
          enhanceContrast: options.enhanceContrast,
          captureOriginalPreview: pageIndex == 0,
        ),
      );

      if (pageIndex == 0) {
        firstBeforeBytes =
            preprocessed.originalPreviewBytes ?? preprocessed.workingImageBytes;
        firstPageWidth = preprocessed.width;
        firstPageHeight = preprocessed.height;
      }

      final stagedPayload = await ImagePayloadProcessor.prepareFromBytes(
        preprocessed.workingImageBytes,
      );
      final OcrResult ocr;
      List<DetectedFaceRegion> faceRegions = const [];
      try {
        ocr = await ocrEngine.processImage(
          stagedPayload,
          script: options.script,
        );
        if (options.presets.contains(RedactionPreset.faces)) {
          faceRegions =
              await faceDetectionEngine.detectOrientedFaces(stagedPayload);
        }
      } finally {
        await stagedPayload.cleanup();
      }

      final entityItemsByBlock = <int, List<ExtractedEntityItem>>{};
      final extractor = entityExtractionEngine;
      final needsTextEntities =
          options.presets.contains(RedactionPreset.ids) ||
          options.presets.contains(RedactionPreset.contacts) ||
          options.presets.contains(RedactionPreset.addresses);
      if (extractor != null && needsTextEntities) {
        try {
          final available = await extractor.isNativeModelAvailable();
          if (available) {
            for (var blockIdx = 0; blockIdx < ocr.blocks.length; blockIdx++) {
              final block = ocr.blocks[blockIdx];
              final resolvedLines =
                  block.lines.map(_resolveLineSpans).toList();
              final joined = _buildResolvedBlockText(resolvedLines).blockText;
              if (joined.trim().isEmpty) continue;
              final items = await extractor.extractEntities(joined);
              if (items.isNotEmpty) {
                entityItemsByBlock[blockIdx] = items;
              }
            }
          }
        } catch (_) {
          // Deterministic rules remain authoritative if ML Kit extraction fails.
        }
      }

      final detection = _detectPageRedactions(
        ocr: ocr,
        faceRegions: faceRegions,
        pageIndex: pageIndex,
        options: options,
        entityItemsByBlock: entityItemsByBlock,
      );

      for (final spec in detection.burnSpecs) {
        allRegions.add(spec.region);
        categoryCounts[spec.region.category] =
            (categoryCounts[spec.region.category] ?? 0) + 1;
      }

      if (detection.sanitizedOcr.text.trim().isNotEmpty) {
        if (sanitizedTextBuffer.isNotEmpty) {
          sanitizedTextBuffer.writeln();
          sanitizedTextBuffer.writeln();
        }
        sanitizedTextBuffer.write(detection.sanitizedOcr.text.trim());
      }

      final burnedBytes = await Isolate.run(
        () => _burnRedactionsInIsolate(
          workingImageBytes: preprocessed.workingImageBytes,
          burnSpecs: detection.burnSpecs,
          stripMetadata: options.stripMetadata,
        ),
      );

      if (pageIndex == 0) {
        firstAfterBytes = burnedBytes;
      }

      stagedSanitizedPages.add(
        _StagedSanitizedPage(
          pageIndex: pageIndex,
          sanitizedPngBytes: burnedBytes,
          width: preprocessed.width,
          height: preprocessed.height,
          sanitizedOcr: detection.sanitizedOcr,
        ),
      );
    }

    Uint8List? pdfBytes;
    if (options.outputFormat == RedactionOutputFormat.pdf ||
        options.outputFormat == RedactionOutputFormat.json) {
      pdfBytes = await Isolate.run(
        () => _buildSanitizedPdfInIsolate(
          pages: stagedSanitizedPages,
          pageFormat: options.pageFormat,
          stripMetadata: options.stripMetadata,
        ),
      );
    }

    stopwatch.stop();

    final outputBytes = options.outputFormat == RedactionOutputFormat.pdf
        ? pdfBytes!
        : firstAfterBytes!;
    final outputMimeType = options.outputFormat == RedactionOutputFormat.pdf
        ? "application/pdf"
        : "image/png";

    return RedactionResult(
      outputBytes: outputBytes,
      outputMimeType: outputMimeType,
      pdfBytes: pdfBytes,
      beforeImageBytes: firstBeforeBytes!,
      afterImageBytes: firstAfterBytes!,
      pageCount: stagedSanitizedPages.length,
      redactedCount: allRegions.length,
      categoryCounts: categoryCounts,
      regions: allRegions,
      metadataStripped: options.stripMetadata,
      keepLast4: options.keepLast4,
      contrastEnhanced: options.enhanceContrast,
      processingMs: stopwatch.elapsedMilliseconds,
      sanitizedText: sanitizedTextBuffer.toString(),
      imageWidth: firstPageWidth,
      imageHeight: firstPageHeight,
    );
  }

  static ({List<_BurnRegionSpec> burnSpecs, OcrResult sanitizedOcr})
      _detectPageRedactions({
    required OcrResult ocr,
    required List<DetectedFaceRegion> faceRegions,
    required int pageIndex,
    required RedactionOptions options,
    Map<int, List<ExtractedEntityItem>> entityItemsByBlock = const {},
  }) {
    final burnSpecs = <_BurnRegionSpec>[];
    final sanitizedBlocks = <OcrTextBlock>[];

    // Pass 1: Resolve all line spans, classify potential field headers, and
    // run deterministic single-line matchers.
    final resolvedByBlock = <int, List<({String text, List<_ElementSpan> spans})>>{};
    final pageLines = <_IndexedLine>[];
    final candidatesByLine = <(int, int), List<_PiiMatchCandidate>>{};

    for (var blockIdx = 0; blockIdx < ocr.blocks.length; blockIdx++) {
      final block = ocr.blocks[blockIdx];
      final resolvedLines = <({String text, List<_ElementSpan> spans})>[];

      for (var lineIdx = 0; lineIdx < block.lines.length; lineIdx++) {
        final line = block.lines[lineIdx];
        final lineData = _resolveLineSpans(line);
        resolvedLines.add(lineData);

        final scanText = _normaliseIndicDigits(lineData.text);
        final sameLinePair = _splitSameLineHeaderValue(scanText);
        final headerKind = sameLinePair != null
            ? null
            : _classifyHeaderLine(scanText);

        pageLines.add(
          _IndexedLine(
            blockIndex: blockIdx,
            lineIndex: lineIdx,
            line: line,
            text: lineData.text,
            spans: lineData.spans,
            headerKind: headerKind,
            isStandaloneHeader:
                sameLinePair == null &&
                headerKind != null &&
                headerKind != _FieldHeaderKind.otherField,
          ),
        );

        final lineCandidates = _findLineCandidates(
          lineText: lineData.text,
          presets: options.presets,
        );
        if (lineCandidates.isNotEmpty) {
          candidatesByLine[(blockIdx, lineIdx)] = lineCandidates;
        }
      }

      resolvedByBlock[blockIdx] = resolvedLines;
    }

    // Pass 2: Propagate standalone multilingual headers (ID, Address, Name,
    // DOB) onto immediately following or spatially aligned value lines below.
    _propagateStackedHeaderCandidates(
      pageLines: pageLines,
      presets: options.presets,
      candidatesByLine: candidatesByLine,
    );

    // Pass 3: Project optional offline ML Kit Entity Extraction matches back
    // onto individual OCR lines when the native model is cached on device.
    for (final entry in entityItemsByBlock.entries) {
      final blockIdx = entry.key;
      final resolvedLines = resolvedByBlock[blockIdx];
      if (resolvedLines == null || resolvedLines.isEmpty) continue;
      _mapBlockEntitiesToLines(
        blockIndex: blockIdx,
        resolvedLines: resolvedLines,
        entities: entry.value,
        presets: options.presets,
        candidatesByLine: candidatesByLine,
      );
    }

    // Pass 4: Deduplicate candidates per line, burn masks, and rebuild OCR.
    for (var blockIdx = 0; blockIdx < ocr.blocks.length; blockIdx++) {
      final block = ocr.blocks[blockIdx];
      final resolvedLines = resolvedByBlock[blockIdx] ?? const [];
      final sanitizedLines = <OcrTextLine>[];

      for (var lineIdx = 0; lineIdx < block.lines.length; lineIdx++) {
        final line = block.lines[lineIdx];
        final lineData = resolvedLines[lineIdx];
        final rawCandidates = candidatesByLine[(blockIdx, lineIdx)];
        final candidates = rawCandidates == null
            ? const <_PiiMatchCandidate>[]
            : _deduplicateCandidates(rawCandidates);

        if (candidates.isEmpty) {
          sanitizedLines.add(line);
          continue;
        }

        final redactedElementIndices = <int, String>{};
        var sanitizedLineText = lineData.text;

        // Apply replacements from back to front so character offsets stay valid.
        final sortedCandidates = List<_PiiMatchCandidate>.from(candidates)
          ..sort((a, b) => b.start.compareTo(a.start));

        for (final match in sortedCandidates) {
          final maskLabel = _buildMaskPreview(
            category: match.category,
            matchedText: match.matchedText,
            keepLast4: options.keepLast4 && match.supportsKeepLast4,
            maskPreviewOverride: match.maskPreviewOverride,
          );
          sanitizedLineText = sanitizedLineText.replaceRange(
            match.start,
            match.end,
            maskLabel,
          );

          final boxSpec = _computeMatchBox(
            line: line,
            lineText: lineData.text,
            spans: lineData.spans,
            match: match,
            keepLast4: options.keepLast4 && match.supportsKeepLast4,
          );
          if (boxSpec != null) {
            burnSpecs.add(
              _BurnRegionSpec(
                region: RedactedRegion(
                  pageIndex: pageIndex,
                  category: match.category,
                  boundingBox: boxSpec.box,
                  cornerPoints: boxSpec.cornerPoints,
                  maskedPreview: maskLabel,
                ),
                expandRightEdge: boxSpec.expandRightEdge,
              ),
            );
          }

          for (final span in lineData.spans) {
            if (span.end > match.start && span.start < match.end) {
              redactedElementIndices[span.index] = maskLabel;
            }
          }
        }

        final updatedElements = <OcrTextElement>[];
        for (var i = 0; i < line.elements.length; i++) {
          final elem = line.elements[i];
          final replacement = redactedElementIndices[i];
          if (replacement == null) {
            updatedElements.add(elem);
          } else {
            updatedElements.add(
              OcrTextElement(
                text: replacement,
                boundingBox: elem.boundingBox,
                cornerPoints: elem.cornerPoints,
                recognizedLanguages: elem.recognizedLanguages,
                confidence: elem.confidence,
              ),
            );
          }
        }

        sanitizedLines.add(
          OcrTextLine(
            text: sanitizedLineText,
            boundingBox: line.boundingBox,
            cornerPoints: line.cornerPoints,
            recognizedLanguages: line.recognizedLanguages,
            confidence: line.confidence,
            elements: updatedElements,
          ),
        );
      }

      sanitizedBlocks.add(
        OcrTextBlock(
          text: sanitizedLines.map((l) => l.text).join("\n"),
          boundingBox: block.boundingBox,
          cornerPoints: block.cornerPoints,
          recognizedLanguages: block.recognizedLanguages,
          lines: sanitizedLines,
        ),
      );
    }

    for (final face in faceRegions) {
      burnSpecs.add(
        _BurnRegionSpec(
          region: RedactedRegion(
            pageIndex: pageIndex,
            category: "face",
            boundingBox: face.boundingBox,
            cornerPoints: face.cornerPoints,
            maskedPreview: "[FACE REDACTED]",
          ),
          expandRightEdge: true,
        ),
      );
    }

    final sanitizedOcr = OcrResult(
      text: sanitizedBlocks.map((b) => b.text).join("\n\n"),
      script: ocr.script,
      blocks: sanitizedBlocks,
      detectedLanguages: ocr.detectedLanguages,
      inferenceMs: ocr.inferenceMs,
      imageWidth: ocr.imageWidth,
      imageHeight: ocr.imageHeight,
    );

    return (burnSpecs: burnSpecs, sanitizedOcr: sanitizedOcr);
  }

  static ({String text, List<_ElementSpan> spans}) _resolveLineSpans(
    OcrTextLine line,
  ) {
    if (line.elements.isEmpty) {
      return (text: line.text, spans: const []);
    }

    final spans = <_ElementSpan>[];
    final text = line.text;
    var cursor = 0;
    var allMatchedInOrder = true;

    for (var i = 0; i < line.elements.length; i++) {
      final elem = line.elements[i];
      final found = text.indexOf(elem.text, cursor);
      if (found == -1) {
        allMatchedInOrder = false;
        break;
      }
      spans.add(
        _ElementSpan(
          index: i,
          start: found,
          end: found + elem.text.length,
          element: elem,
        ),
      );
      cursor = found + elem.text.length;
    }

    if (allMatchedInOrder && spans.length == line.elements.length) {
      return (text: text, spans: spans);
    }

    // Reconstruct a canonical line string if element tokens differ slightly
    // from `line.text` spacing.
    final rebuilt = StringBuffer();
    final fallbackSpans = <_ElementSpan>[];
    for (var i = 0; i < line.elements.length; i++) {
      if (i > 0) rebuilt.write(" ");
      final elem = line.elements[i];
      final start = rebuilt.length;
      rebuilt.write(elem.text);
      fallbackSpans.add(
        _ElementSpan(
          index: i,
          start: start,
          end: rebuilt.length,
          element: elem,
        ),
      );
    }
    return (text: rebuilt.toString(), spans: fallbackSpans);
  }

  static String _normaliseIndicDigits(String input) {
    final buffer = StringBuffer();
    var changed = false;
    for (final unit in input.codeUnits) {
      if (unit >= 0x0966 && unit <= 0x096F) {
        buffer.writeCharCode(0x0030 + (unit - 0x0966));
        changed = true;
      } else {
        buffer.writeCharCode(unit);
      }
    }
    return changed ? buffer.toString() : input;
  }

  static List<_PiiMatchCandidate> _findLineCandidates({
    required String lineText,
    required Set<RedactionPreset> presets,
  }) {
    final scanText = _normaliseIndicDigits(lineText);
    final candidates = <_PiiMatchCandidate>[];

    if (presets.contains(RedactionPreset.ids)) {
      final mrzCandidate = _detectMrzCandidate(scanText);
      if (mrzCandidate != null) {
        candidates.add(mrzCandidate);
      }

      for (final m in _groupedCardRegex.allMatches(scanText)) {
        candidates.add(
          _PiiMatchCandidate(
            category: "id",
            start: m.start,
            end: m.end,
            matchedText: m.group(0)!,
            supportsKeepLast4: true,
          ),
        );
      }
      for (final m in _compactCardRegex.allMatches(scanText)) {
        final raw = m.group(0)!.trim();
        final digitsOnly = raw.replaceAll(RegExp(r"\D"), "");
        if (digitsOnly.length >= 13 &&
            digitsOnly.length <= 19 &&
            _passesLuhn(digitsOnly)) {
          candidates.add(
            _PiiMatchCandidate(
              category: "id",
              start: m.start,
              end: m.end,
              matchedText: raw,
              supportsKeepLast4: true,
            ),
          );
        }
      }
      for (final m in _ssnRegex.allMatches(scanText)) {
        candidates.add(
          _PiiMatchCandidate(
            category: "id",
            start: m.start,
            end: m.end,
            matchedText: m.group(0)!,
            supportsKeepLast4: true,
          ),
        );
      }
      for (final m in _aadhaarRegex.allMatches(scanText)) {
        candidates.add(
          _PiiMatchCandidate(
            category: "id",
            start: m.start,
            end: m.end,
            matchedText: m.group(0)!,
            supportsKeepLast4: true,
          ),
        );
      }
      for (final m in _gstinRegex.allMatches(scanText)) {
        candidates.add(
          _PiiMatchCandidate(
            category: "id",
            start: m.start,
            end: m.end,
            matchedText: m.group(0)!,
            supportsKeepLast4: true,
          ),
        );
      }
      for (final m in _panRegex.allMatches(scanText)) {
        candidates.add(
          _PiiMatchCandidate(
            category: "id",
            start: m.start,
            end: m.end,
            matchedText: m.group(0)!,
            supportsKeepLast4: true,
          ),
        );
      }
      for (final m in _voterIdRegex.allMatches(scanText)) {
        candidates.add(
          _PiiMatchCandidate(
            category: "id",
            start: m.start,
            end: m.end,
            matchedText: m.group(0)!,
            supportsKeepLast4: true,
          ),
        );
      }
      for (final m in _indianDlRegex.allMatches(scanText)) {
        candidates.add(
          _PiiMatchCandidate(
            category: "id",
            start: m.start,
            end: m.end,
            matchedText: m.group(0)!,
            supportsKeepLast4: true,
          ),
        );
      }
      for (final m in _indianPassportRegex.allMatches(scanText)) {
        candidates.add(
          _PiiMatchCandidate(
            category: "id",
            start: m.start,
            end: m.end,
            matchedText: m.group(0)!,
            supportsKeepLast4: true,
          ),
        );
      }
      for (final m in _singaporeNricRegex.allMatches(scanText)) {
        candidates.add(
          _PiiMatchCandidate(
            category: "id",
            start: m.start,
            end: m.end,
            matchedText: m.group(0)!,
            supportsKeepLast4: true,
          ),
        );
      }
      for (final m in _ukNiRegex.allMatches(scanText)) {
        candidates.add(
          _PiiMatchCandidate(
            category: "id",
            start: m.start,
            end: m.end,
            matchedText: m.group(0)!,
            supportsKeepLast4: true,
          ),
        );
      }
      for (final m in _ukDlRegex.allMatches(scanText)) {
        candidates.add(
          _PiiMatchCandidate(
            category: "id",
            start: m.start,
            end: m.end,
            matchedText: m.group(0)!,
            supportsKeepLast4: true,
          ),
        );
      }
      for (final m in _ifscRegex.allMatches(scanText)) {
        candidates.add(
          _PiiMatchCandidate(
            category: "id",
            start: m.start,
            end: m.end,
            matchedText: m.group(0)!,
            supportsKeepLast4: true,
          ),
        );
      }
      for (final m in _ibanRegex.allMatches(scanText)) {
        candidates.add(
          _PiiMatchCandidate(
            category: "id",
            start: m.start,
            end: m.end,
            matchedText: m.group(0)!,
            supportsKeepLast4: true,
          ),
        );
      }
      for (final m in _labeledIdRegex.allMatches(scanText)) {
        final rawValue = m.group(1);
        if (rawValue == null) continue;
        final value = rawValue.trimRight();
        if (value.isEmpty) continue;
        final valueStart = m.group(0)!.lastIndexOf(value);
        if (valueStart == -1) continue;
        final absStart = m.start + valueStart;
        candidates.add(
          _PiiMatchCandidate(
            category: "id",
            start: absStart,
            end: absStart + value.length,
            matchedText: value,
            supportsKeepLast4: true,
          ),
        );
      }
    }

    if (presets.contains(RedactionPreset.contacts)) {
      for (final m in _upiRegex.allMatches(scanText)) {
        candidates.add(
          _PiiMatchCandidate(
            category: "contact",
            start: m.start,
            end: m.end,
            matchedText: m.group(0)!,
            supportsKeepLast4: false,
          ),
        );
      }
      for (final m in _emailRegex.allMatches(scanText)) {
        candidates.add(
          _PiiMatchCandidate(
            category: "contact",
            start: m.start,
            end: m.end,
            matchedText: m.group(0)!,
            supportsKeepLast4: false,
          ),
        );
      }
      for (final m in _indianMobileRegex.allMatches(scanText)) {
        candidates.add(
          _PiiMatchCandidate(
            category: "contact",
            start: m.start,
            end: m.end,
            matchedText: m.group(0)!,
            supportsKeepLast4: false,
          ),
        );
      }
      for (final m in _phoneRegex.allMatches(scanText)) {
        final digits = m.group(0)!.replaceAll(RegExp(r"\D"), "");
        if (digits.length >= 7 && digits.length <= 15) {
          candidates.add(
            _PiiMatchCandidate(
              category: "contact",
              start: m.start,
              end: m.end,
              matchedText: m.group(0)!,
              supportsKeepLast4: false,
            ),
          );
        }
      }
      for (final m in _intlPhoneRegex.allMatches(scanText)) {
        final digits = m.group(0)!.replaceAll(RegExp(r"\D"), "");
        if (digits.length >= 8 && digits.length <= 15) {
          candidates.add(
            _PiiMatchCandidate(
              category: "contact",
              start: m.start,
              end: m.end,
              matchedText: m.group(0)!,
              supportsKeepLast4: false,
            ),
          );
        }
      }
      for (final m in _labeledPhoneRegex.allMatches(scanText)) {
        final value = m.group(1)?.trim();
        if (value == null || value.isEmpty) continue;
        final digits = value.replaceAll(RegExp(r"\D"), "");
        if (digits.length < 7) continue;
        final valueStart = m.group(0)!.indexOf(value);
        if (valueStart == -1) continue;
        final absStart = m.start + valueStart;
        candidates.add(
          _PiiMatchCandidate(
            category: "contact",
            start: absStart,
            end: absStart + value.length,
            matchedText: value,
            supportsKeepLast4: false,
          ),
        );
      }
    }

    if (presets.contains(RedactionPreset.addresses)) {
      final labeledMatch = _labeledAddressRegex.firstMatch(scanText);
      if (labeledMatch != null) {
        final value = labeledMatch.group(1)?.trim();
        if (value != null && value.length >= 5) {
          final start = scanText.indexOf(value, labeledMatch.start);
          if (start != -1) {
            candidates.add(
              _PiiMatchCandidate(
                category: "address",
                start: start,
                end: start + value.length,
                matchedText: value,
                supportsKeepLast4: false,
              ),
            );
          }
        }
      }
      for (final m in _streetAddressRegex.allMatches(scanText)) {
        candidates.add(
          _PiiMatchCandidate(
            category: "address",
            start: m.start,
            end: m.end,
            matchedText: m.group(0)!,
            supportsKeepLast4: false,
          ),
        );
      }
      for (final m in _europeanStreetAddressRegex.allMatches(scanText)) {
        candidates.add(
          _PiiMatchCandidate(
            category: "address",
            start: m.start,
            end: m.end,
            matchedText: m.group(0)!,
            supportsKeepLast4: false,
          ),
        );
      }
      for (final m in _ukPostcodeAddressRegex.allMatches(scanText)) {
        candidates.add(
          _PiiMatchCandidate(
            category: "address",
            start: m.start,
            end: m.end,
            matchedText: m.group(0)!,
            supportsKeepLast4: false,
          ),
        );
      }
      for (final m in _euPostalCityRegex.allMatches(scanText)) {
        candidates.add(
          _PiiMatchCandidate(
            category: "address",
            start: m.start,
            end: m.end,
            matchedText: m.group(0)!,
            supportsKeepLast4: false,
          ),
        );
      }
      for (final m in _singaporeAddressLineRegex.allMatches(scanText)) {
        candidates.add(
          _PiiMatchCandidate(
            category: "address",
            start: m.start,
            end: m.end,
            matchedText: m.group(0)!,
            supportsKeepLast4: false,
          ),
        );
      }
      for (final m in _indianAddressLineRegex.allMatches(scanText)) {
        candidates.add(
          _PiiMatchCandidate(
            category: "address",
            start: m.start,
            end: m.end,
            matchedText: m.group(0)!,
            supportsKeepLast4: false,
          ),
        );
      }
      for (final m in _postalAddressLineRegex.allMatches(scanText)) {
        candidates.add(
          _PiiMatchCandidate(
            category: "address",
            start: m.start,
            end: m.end,
            matchedText: m.group(0)!,
            supportsKeepLast4: false,
          ),
        );
      }
    }

    final sameLinePair = _splitSameLineHeaderValue(scanText);
    if (sameLinePair != null) {
      final candidate = _buildHeaderValueCandidate(
        kind: sameLinePair.kind,
        value: sameLinePair.value,
        start: sameLinePair.valueStart,
        end: sameLinePair.valueEnd,
        presets: presets,
      );
      if (candidate != null) {
        candidates.add(candidate);
      }
    }

    return _deduplicateCandidates(candidates);
  }

  static ({
    String blockText,
    List<({int lineIndex, int start, int end})> lineRanges,
  }) _buildResolvedBlockText(
    List<({String text, List<_ElementSpan> spans})> resolvedLines,
  ) {
    final buffer = StringBuffer();
    final ranges = <({int lineIndex, int start, int end})>[];
    for (var i = 0; i < resolvedLines.length; i++) {
      if (i > 0) buffer.write("\n");
      final start = buffer.length;
      buffer.write(resolvedLines[i].text);
      ranges.add((lineIndex: i, start: start, end: buffer.length));
    }
    return (blockText: buffer.toString(), lineRanges: ranges);
  }

  static _PiiMatchCandidate? _detectMrzCandidate(String scanText) {
    final trimmed = scanText.trim();
    if (trimmed.isEmpty) return null;
    final compact = trimmed.replaceAll(RegExp(r"\s+"), "");
    if (compact.length < 24 || compact.length > 48) return null;
    if (!RegExp(r"^[A-Z0-9<«‹]+$").hasMatch(compact)) return null;
    final chevronCount = RegExp(r"[<«‹]").allMatches(compact).length;
    final hasDoubleChevron =
        compact.contains("<<") ||
        compact.contains("««") ||
        compact.contains("‹‹");
    if (!hasDoubleChevron && chevronCount < 4) return null;

    final start = scanText.indexOf(trimmed);
    if (start == -1) return null;
    return _PiiMatchCandidate(
      category: "id",
      start: start,
      end: start + trimmed.length,
      matchedText: trimmed,
      supportsKeepLast4: false,
      maskPreviewOverride: "[REDACTED MRZ]",
    );
  }

  static const Set<String> _idHeaderSegments = {
    "id no",
    "id number",
    "id num",
    "id #",
    "identity no",
    "identity number",
    "document no",
    "document number",
    "doc no",
    "dokumentennummer",
    "ausweisnummer",
    "personalnummer",
    "kennnummer",
    "zugangsnummer",
    "card access number",
    "passport no",
    "passport number",
    "n° de passeport",
    "numéro de passeport",
    "licence no",
    "license no",
    "licence number",
    "license number",
    "driver's licence no",
    "driver's license no",
    "driving licence no",
    "dl no",
    "national insurance no",
    "national insurance number",
    "ni no",
    "ni number",
    "nric",
    "nric no",
    "fin",
    "ssn",
    "sin",
    "tin",
    "ein",
    "tax id",
    "aadhaar",
    "aadhaar no",
    "aadhar",
    "uid",
    "pan",
    "gstin",
    "epic",
    "voter id",
    "account no",
    "account number",
    "policy no",
    "身份证号码",
    "证件号码",
    "आधार",
    "पैन",
    "पहचान संख्या",
  };

  static const Set<String> _addressHeaderSegments = {
    "address",
    "addr",
    "residential address",
    "permanent address",
    "home address",
    "mailing address",
    "current address",
    "residence",
    "place of residence",
    "location",
    "anschrift",
    "adresse",
    "wohnort",
    "wohnsitz",
    "domicile",
    "dirección",
    "direccion",
    "indirizzo",
    "adres",
    "endereço",
    "endereco",
    "morada",
    "住所",
    "地址",
    "住址",
    "पता",
    "स्थायी पता",
  };

  static const Set<String> _nameHeaderSegments = {
    "name",
    "full name",
    "surname",
    "last name",
    "family name",
    "first name",
    "first name(s)",
    "first names",
    "given name",
    "given names",
    "middle name",
    "other name",
    "other names",
    "secondary name",
    "maiden name",
    "father's name",
    "father name",
    "mother's name",
    "mother name",
    "spouse name",
    "spouse's name",
    "holder's name",
    "holder name",
    "cardholder name",
    "alias",
    "vorname",
    "vornamen",
    "nachname",
    "familienname",
    "vatername",
    "zweitname",
    "geburtsname",
    "künstlername",
    "nom",
    "nom de famille",
    "prénom",
    "prenom",
    "prénoms",
    "prenoms",
    "nom d'usage",
    "nombre",
    "apellido",
    "apellidos",
    "cognome",
    "nome",
    "achternaam",
    "voornamen",
    "姓名",
    "别名",
    "नाम",
    "पिता का नाम",
  };

  static const Set<String> _dobHeaderSegments = {
    "dob",
    "d.o.b",
    "date of birth",
    "birth date",
    "birthdate",
    "date & place of birth",
    "date and place of birth",
    "geburtsdatum",
    "geb.-datum",
    "geburtstag",
    "date de naissance",
    "né(e) le",
    "fecha de nacimiento",
    "data di nascita",
    "geboortedatum",
    "data de nascimento",
    "出生日期",
    "जन्म तिथि",
    "जन्म दिनांक",
  };

  static const Set<String> _otherFieldHeaderSegments = {
    "status",
    "nationality",
    "nationalität",
    "staatsangehörigkeit",
    "sex",
    "sexe",
    "gender",
    "geschlecht",
    "race",
    "种族",
    "身份",
    "date of issue",
    "date de délivrance",
    "date of expiry",
    "date d'expiration",
    "issued by",
    "authority",
    "autorité",
    "country of birth",
    "出生国",
    "place of birth",
    "geburtsort",
    "signature",
    "holder's signature",
    "signature du titulaire",
    "height",
    "größe",
    "eye colour",
    "eye color",
    "augenfarbe",
    "blood group",
    "type",
    "code",
    "class",
    "category",
    "categories",
    "restrictions",
    "specimen",
    "test card",
    "photograph",
    "valid from",
    "valid to",
    "valid until",
    "codes",
  };

  static String _normaliseHeaderSegment(String rawSegment) {
    var cleaned = rawSegment.trim().toLowerCase();
    // Strip optional leading numbered field prefix such as "5.", "4a.", "8)".
    cleaned = cleaned.replaceFirst(RegExp(r"^\d{1,2}[a-z]?[.)]\s+"), "");
    // Strip trailing colon, full-width colon, dash, dot, or whitespace.
    cleaned = cleaned.replaceAll(RegExp(r"[\s:：\-.]+$"), "").trim();
    return cleaned.replaceAll(RegExp(r"\s+"), " ");
  }

  static _FieldHeaderKind? _classifyHeaderSegment(String rawSegment) {
    final norm = _normaliseHeaderSegment(rawSegment);
    if (norm.isEmpty) return null;
    if (_idHeaderSegments.contains(norm)) return _FieldHeaderKind.id;
    if (_addressHeaderSegments.contains(norm)) return _FieldHeaderKind.address;
    if (_nameHeaderSegments.contains(norm)) return _FieldHeaderKind.name;
    if (_dobHeaderSegments.contains(norm)) return _FieldHeaderKind.dob;
    if (_otherFieldHeaderSegments.contains(norm)) {
      return _FieldHeaderKind.otherField;
    }
    return null;
  }

  static _FieldHeaderKind? _classifyHeaderLine(
    String rawLine, {
    bool allowUnknownEndColon = true,
  }) {
    final trimmed = rawLine.trim();
    if (trimmed.isEmpty ||
        trimmed.length > 72 ||
        RegExp(r"\d{4,}").hasMatch(trimmed)) {
      return null;
    }

    const headerPriority = {
      _FieldHeaderKind.id: 5,
      _FieldHeaderKind.address: 4,
      _FieldHeaderKind.name: 3,
      _FieldHeaderKind.dob: 2,
      _FieldHeaderKind.otherField: 1,
    };

    _FieldHeaderKind? bestKind;
    final segments = trimmed.split(RegExp(r"\s*[/|·]\s*"));
    for (final segment in segments) {
      final kind = _classifyHeaderSegment(segment);
      if (kind == null) continue;
      if (bestKind == null ||
          (headerPriority[kind] ?? 0) > (headerPriority[bestKind] ?? 0)) {
        bestKind = kind;
      }
    }
    if (bestKind != null) {
      return bestKind;
    }

    if (!allowUnknownEndColon) return null;

    if ((trimmed.endsWith(":") || trimmed.endsWith("：")) &&
        !RegExp(r"\d{3,}").hasMatch(trimmed)) {
      return _FieldHeaderKind.otherField;
    }

    if (RegExp(r"^\d{1,2}[a-z]?[.)]\s+[A-Za-zÀ-ÿ]").hasMatch(trimmed) &&
        trimmed.length <= 36 &&
        !RegExp(
          r"\b(?:Street|St|Avenue|Ave|Road|Rd|Boulevard|Blvd|Lane|Ln|Drive|Dr|Court|Ct|Way|Parkway|Pkwy|Circle|Cir|Place|Pl|Rue|Via|Calle|Strasse|Straße|Weg)\b",
          caseSensitive: false,
        ).hasMatch(trimmed)) {
      return _FieldHeaderKind.otherField;
    }

    return null;
  }

  static ({
    _FieldHeaderKind kind,
    String value,
    int valueStart,
    int valueEnd,
  })? _splitSameLineHeaderValue(String scanText) {
    final colonMatch = RegExp(r"[:：]").firstMatch(scanText);
    if (colonMatch == null) return null;
    final colonIdx = colonMatch.start;
    if (scanText.substring(colonIdx).startsWith("://")) return null;

    final left = scanText.substring(0, colonIdx).trim();
    final rightRaw = scanText.substring(colonIdx + 1);
    final value = rightRaw.trim();
    if (left.isEmpty || value.isEmpty) return null;

    final kind = _classifyHeaderLine(left, allowUnknownEndColon: false);
    if (kind == null || kind == _FieldHeaderKind.otherField) return null;

    final relStart = rightRaw.indexOf(value);
    if (relStart == -1) return null;
    final absStart = colonIdx + 1 + relStart;
    return (
      kind: kind,
      value: value,
      valueStart: absStart,
      valueEnd: absStart + value.length,
    );
  }

  static bool _looksLikeIdValue(String raw) {
    final trimmed = raw.trim();
    if (trimmed.length < 4 || trimmed.length > 32) return false;
    if (!RegExp(r"[\d\u0966-\u096F]").hasMatch(trimmed)) return false;
    final normalised = _normaliseIndicDigits(trimmed);
    if (!RegExp(r"^[A-Za-z0-9\s\-/.]+$").hasMatch(normalised)) return false;
    final tokens = normalised.split(RegExp(r"\s+")).where((t) => t.isNotEmpty);
    return tokens.length <= 6;
  }

  static bool _looksLikeNameValue(String raw) {
    final trimmed = raw.trim();
    if (trimmed.length < 2 || trimmed.length > 60) return false;
    if (RegExp(r"[\d\u0966-\u096F]").hasMatch(trimmed)) return false;
    if (RegExp(r"\p{L}", unicode: true).allMatches(trimmed).length < 2) {
      return false;
    }
    if (_classifyHeaderLine(trimmed) != null) return false;
    if (_detectMrzCandidate(trimmed) != null) return false;
    return true;
  }

  static bool _looksLikeDobValue(String raw) {
    final trimmed = raw.trim();
    if (trimmed.length < 4 || trimmed.length > 45) return false;
    if (!RegExp(r"[\d\u0966-\u096F]").hasMatch(trimmed)) return false;
    if (_classifyHeaderLine(trimmed) != null) return false;
    if (_detectMrzCandidate(trimmed) != null) return false;
    return true;
  }

  static _PiiMatchCandidate? _buildHeaderValueCandidate({
    required _FieldHeaderKind kind,
    required String value,
    required int start,
    required int end,
    required Set<RedactionPreset> presets,
  }) {
    switch (kind) {
      case _FieldHeaderKind.id:
        if (!presets.contains(RedactionPreset.ids) ||
            !_looksLikeIdValue(value)) {
          return null;
        }
        return _PiiMatchCandidate(
          category: "id",
          start: start,
          end: end,
          matchedText: value,
          supportsKeepLast4: true,
        );
      case _FieldHeaderKind.address:
        if (!presets.contains(RedactionPreset.addresses) || value.length < 4) {
          return null;
        }
        return _PiiMatchCandidate(
          category: "address",
          start: start,
          end: end,
          matchedText: value,
          supportsKeepLast4: false,
        );
      case _FieldHeaderKind.name:
        final category = presets.contains(RedactionPreset.contacts)
            ? "contact"
            : (presets.contains(RedactionPreset.ids) ? "id" : null);
        if (category == null || !_looksLikeNameValue(value)) {
          return null;
        }
        return _PiiMatchCandidate(
          category: category,
          start: start,
          end: end,
          matchedText: value,
          supportsKeepLast4: false,
          maskPreviewOverride: "[REDACTED NAME]",
        );
      case _FieldHeaderKind.dob:
        final category = presets.contains(RedactionPreset.ids)
            ? "id"
            : (presets.contains(RedactionPreset.contacts) ? "contact" : null);
        if (category == null || !_looksLikeDobValue(value)) {
          return null;
        }
        return _PiiMatchCandidate(
          category: category,
          start: start,
          end: end,
          matchedText: value,
          supportsKeepLast4: false,
          maskPreviewOverride: "[REDACTED DOB]",
        );
      case _FieldHeaderKind.otherField:
        return null;
    }
  }

  static void _propagateStackedHeaderCandidates({
    required List<_IndexedLine> pageLines,
    required Set<RedactionPreset> presets,
    required Map<(int, int), List<_PiiMatchCandidate>> candidatesByLine,
  }) {
    if (pageLines.isEmpty) return;
    final hasAnySpatialBox =
        pageLines.where((l) => l.line.boundingBox != null).length >= 2;

    for (final header in pageLines) {
      if (!header.isStandaloneHeader) continue;
      final kind = header.headerKind;
      if (kind == null || kind == _FieldHeaderKind.otherField) continue;

      final useSpatial = hasAnySpatialBox && header.line.boundingBox != null;
      final maxSteps = kind == _FieldHeaderKind.address ? 3 : 1;
      var anchor = header;
      final visited = <(int, int)>{(header.blockIndex, header.lineIndex)};

      for (var step = 0; step < maxSteps; step++) {
        final _IndexedLine? nextLine = useSpatial
            ? _findNextSpatialValueLine(
                anchor: anchor,
                pageLines: pageLines,
                visited: visited,
                gapFactor: step == 0 ? 2.2 : 1.8,
              )
            : _findNextBlockValueLine(
                header: header,
                step: step,
                pageLines: pageLines,
              );
        if (nextLine == null) break;
        visited.add((nextLine.blockIndex, nextLine.lineIndex));

        final trimmed = nextLine.text.trim();
        if (trimmed.isEmpty) break;
        if (nextLine.headerKind != null) break;
        final normalised = _normaliseIndicDigits(nextLine.text);
        if (_detectMrzCandidate(normalised) != null) break;

        if (kind == _FieldHeaderKind.address &&
            !RegExp(r"[\p{L}\d]{2}", unicode: true).hasMatch(trimmed)) {
          break;
        }

        final start = nextLine.text.indexOf(trimmed);
        if (start == -1) break;
        final candidate = _buildHeaderValueCandidate(
          kind: kind,
          value: trimmed,
          start: start,
          end: start + trimmed.length,
          presets: presets,
        );
        if (candidate == null) break;

        candidatesByLine
            .putIfAbsent((nextLine.blockIndex, nextLine.lineIndex), () => [])
            .add(candidate);
        anchor = nextLine;
      }
    }
  }

  static _IndexedLine? _findNextBlockValueLine({
    required _IndexedLine header,
    required int step,
    required List<_IndexedLine> pageLines,
  }) {
    final targetLineIndex = header.lineIndex + 1 + step;
    for (final line in pageLines) {
      if (line.blockIndex == header.blockIndex &&
          line.lineIndex == targetLineIndex) {
        return line;
      }
    }
    return null;
  }

  static _IndexedLine? _findNextSpatialValueLine({
    required _IndexedLine anchor,
    required List<_IndexedLine> pageLines,
    required Set<(int, int)> visited,
    required double gapFactor,
  }) {
    final anchorBox = anchor.line.boundingBox;
    if (anchorBox == null) return null;

    final anchorHeight = math.max(1.0, anchorBox.height);
    final anchorCenterY = (anchorBox.top + anchorBox.bottom) / 2.0;

    final matches = <_IndexedLine>[];
    for (final cand in pageLines) {
      if (identical(cand, anchor) ||
          visited.contains((cand.blockIndex, cand.lineIndex))) {
        continue;
      }
      final candBox = cand.line.boundingBox;
      if (candBox == null) continue;

      final candHeight = math.max(1.0, candBox.height);
      final candCenterY = (candBox.top + candBox.bottom) / 2.0;
      if (candCenterY <=
          anchorCenterY + math.min(anchorHeight, candHeight) * 0.25) {
        continue;
      }

      final gapY = candBox.top - anchorBox.bottom;
      final maxGapY = math.max(anchorHeight, candHeight) * gapFactor;
      if (gapY < -anchorHeight * 0.35 || gapY > maxGapY) {
        continue;
      }

      final overlapX =
          math.min(anchorBox.right, candBox.right) -
          math.max(anchorBox.left, candBox.left);
      final minWidth = math.max(1.0, math.min(anchorBox.width, candBox.width));
      final hasOverlap = overlapX >= minWidth * 0.2;
      final leftAligned =
          (candBox.left - anchorBox.left).abs() <=
          math.max(anchorHeight, candHeight) * 2.5;
      if (!hasOverlap && !leftAligned) continue;

      if (candBox.left >= anchorBox.right + anchorHeight ||
          candBox.right <= anchorBox.left - anchorHeight) {
        continue;
      }

      matches.add(cand);
    }

    if (matches.isEmpty) return null;
    matches.sort((a, b) {
      final aBox = a.line.boundingBox!;
      final bBox = b.line.boundingBox!;
      final topDiff = aBox.top.compareTo(bBox.top);
      if (topDiff != 0) return topDiff;
      final aDx = (aBox.left - anchorBox.left).abs();
      final bDx = (bBox.left - anchorBox.left).abs();
      return aDx.compareTo(bDx);
    });
    return matches.first;
  }

  static void _mapBlockEntitiesToLines({
    required int blockIndex,
    required List<({String text, List<_ElementSpan> spans})> resolvedLines,
    required List<ExtractedEntityItem> entities,
    required Set<RedactionPreset> presets,
    required Map<(int, int), List<_PiiMatchCandidate>> candidatesByLine,
  }) {
    final built = _buildResolvedBlockText(resolvedLines);
    final blockText = built.blockText;
    if (blockText.trim().isEmpty) return;

    for (final item in entities) {
      final ({String category, bool supportsKeepLast4})? mapping =
          switch (item.type) {
            "address" when presets.contains(RedactionPreset.addresses) => (
              category: "address",
              supportsKeepLast4: false,
            ),
            "iban" ||
            "payment_card" when presets.contains(RedactionPreset.ids) => (
              category: "id",
              supportsKeepLast4: true,
            ),
            "email" ||
            "phone" ||
            "upi" when presets.contains(RedactionPreset.contacts) => (
              category: "contact",
              supportsKeepLast4: false,
            ),
            _ => null,
          };
      if (mapping == null) continue;

      final trimmedRaw = item.rawValue.trim();
      if (trimmedRaw.length < 5) continue;

      final tokens = trimmedRaw
          .split(RegExp(r"\s+"))
          .where((t) => t.isNotEmpty)
          .toList();
      if (tokens.isEmpty) continue;

      final pattern = RegExp(
        tokens.map(RegExp.escape).join(r"\s+"),
        caseSensitive: false,
      );

      for (final m in pattern.allMatches(blockText)) {
        for (final range in built.lineRanges) {
          if (m.start >= range.end || m.end <= range.start) continue;

          final lineText = resolvedLines[range.lineIndex].text;
          var localStart = math.max(0, m.start - range.start);
          var localEnd = math.min(lineText.length, m.end - range.start);
          while (localStart < localEnd &&
              lineText[localStart].trim().isEmpty) {
            localStart++;
          }
          while (localEnd > localStart &&
              lineText[localEnd - 1].trim().isEmpty) {
            localEnd--;
          }
          if (localEnd <= localStart) continue;

          candidatesByLine
              .putIfAbsent((blockIndex, range.lineIndex), () => [])
              .add(
                _PiiMatchCandidate(
                  category: mapping.category,
                  start: localStart,
                  end: localEnd,
                  matchedText: lineText.substring(localStart, localEnd),
                  supportsKeepLast4: mapping.supportsKeepLast4,
                ),
              );
        }
      }
    }
  }

  static List<_PiiMatchCandidate> _deduplicateCandidates(
    List<_PiiMatchCandidate> raw,
  ) {
    if (raw.length <= 1) return raw;
    const priority = {"id": 3, "contact": 2, "address": 1};
    final sorted = List<_PiiMatchCandidate>.from(raw)
      ..sort((a, b) {
        final pDiff = (priority[b.category] ?? 0) - (priority[a.category] ?? 0);
        if (pDiff != 0) return pDiff;
        return (b.end - b.start) - (a.end - a.start);
      });

    final accepted = <_PiiMatchCandidate>[];
    for (final candidate in sorted) {
      final overlaps = accepted.any(
        (existing) =>
            candidate.start < existing.end && candidate.end > existing.start,
      );
      if (!overlaps) {
        accepted.add(candidate);
      }
    }
    accepted.sort((a, b) => a.start.compareTo(b.start));
    return accepted;
  }

  static bool _passesLuhn(String digits) {
    var sum = 0;
    var alternate = false;
    for (var i = digits.length - 1; i >= 0; i--) {
      var n = digits.codeUnitAt(i) - 48;
      if (n < 0 || n > 9) return false;
      if (alternate) {
        n *= 2;
        if (n > 9) n -= 9;
      }
      sum += n;
      alternate = !alternate;
    }
    return sum % 10 == 0;
  }

  static String _buildMaskPreview({
    required String category,
    required String matchedText,
    required bool keepLast4,
    String? maskPreviewOverride,
  }) {
    if (category == "id") {
      if (keepLast4) {
        final alnumMatches = RegExp(r"[A-Za-z0-9]").allMatches(matchedText);
        if (alnumMatches.length >= 5) {
          final last4 = alnumMatches
              .skip(alnumMatches.length - 4)
              .map((m) => m.group(0)!)
              .join();
          return "••••$last4";
        }
      }
      if (maskPreviewOverride != null) {
        return maskPreviewOverride;
      }
      return "[REDACTED ID]";
    }
    if (maskPreviewOverride != null) {
      return maskPreviewOverride;
    }
    if (category == "contact") {
      if (_upiRegex.hasMatch(matchedText)) {
        return "[REDACTED UPI]";
      }
      return matchedText.contains("@")
          ? "[REDACTED EMAIL]"
          : "[REDACTED PHONE]";
    }
    return "[REDACTED ADDRESS]";
  }

  /// Resolves the exact pixel bounding box and oriented corner polygon covering
  /// the redacted slice of [match], excluding the final 4 characters when
  /// [keepLast4] is enabled.
  static ({
    BoundingBoxRect box,
    List<CornerPoint> cornerPoints,
    bool expandRightEdge,
  })? _computeMatchBox({
    required OcrTextLine line,
    required String lineText,
    required List<_ElementSpan> spans,
    required _PiiMatchCandidate match,
    required bool keepLast4,
  }) {
    var redactionEnd = match.end;
    var trimmedLast4 = false;

    if (keepLast4) {
      final alnumPositions = <int>[];
      for (var i = match.start; i < match.end; i++) {
        final code = lineText.codeUnitAt(i);
        final isAsciiDigit = code >= 48 && code <= 57;
        final isDevanagariDigit = code >= 0x0966 && code <= 0x096F;
        final isUpper = code >= 65 && code <= 90;
        final isLower = code >= 97 && code <= 122;
        if (isAsciiDigit || isDevanagariDigit || isUpper || isLower) {
          alnumPositions.add(i);
        }
      }
      if (alnumPositions.length >= 5) {
        redactionEnd = alnumPositions[alnumPositions.length - 4];
        trimmedLast4 = true;
      }
    }

    if (redactionEnd <= match.start) return null;

    if (spans.isNotEmpty) {
      double? minLeft;
      double? minTop;
      double? maxRight;
      double? maxBottom;
      final slicedQuads = <List<({double x, double y})>>[];
      var hasOrientedCorners = line.cornerPoints.length == 4;

      for (final span in spans) {
        if (span.end <= match.start || span.start >= redactionEnd) {
          continue;
        }
        final box = span.element.boundingBox;
        if (box == null) continue;

        final elemLen = math.max(1, span.end - span.start);
        final localStart = math.max(0, match.start - span.start);
        final localEnd = math.min(elemLen, redactionEnd - span.start);
        if (localEnd <= localStart) continue;

        final tStart = (localStart / elemLen).clamp(0.0, 1.0);
        final tEnd = (localEnd / elemLen).clamp(0.0, 1.0);

        if (span.element.cornerPoints.length == 4) {
          hasOrientedCorners = true;
          slicedQuads.add(_sliceQuad(span.element.cornerPoints, tStart, tEnd));
        } else {
          slicedQuads.add([
            (x: box.left + box.width * tStart, y: box.top),
            (x: box.left + box.width * tEnd, y: box.top),
            (x: box.left + box.width * tEnd, y: box.bottom),
            (x: box.left + box.width * tStart, y: box.bottom),
          ]);
        }

        final sliceLeft = box.left + (box.width * tStart);
        final sliceRight = box.left + (box.width * tEnd);

        minLeft = minLeft == null ? sliceLeft : math.min(minLeft, sliceLeft);
        minTop = minTop == null ? box.top : math.min(minTop, box.top);
        maxRight =
            maxRight == null ? sliceRight : math.max(maxRight, sliceRight);
        maxBottom =
            maxBottom == null ? box.bottom : math.max(maxBottom, box.bottom);
      }

      if (minLeft != null &&
          minTop != null &&
          maxRight != null &&
          maxBottom != null) {
        if (hasOrientedCorners && slicedQuads.isNotEmpty) {
          final frameRef = line.cornerPoints.length == 4
              ? line.cornerPoints
                  .map((p) => (x: p.x.toDouble(), y: p.y.toDouble()))
                  .toList()
              : slicedQuads.first;
          final oriented = _orientUnionQuads(slicedQuads, frameRef);
          if (oriented != null) {
            return (
              box: oriented.box,
              cornerPoints: oriented.cornerPoints,
              expandRightEdge: !trimmedLast4,
            );
          }
        }

        return (
          box: BoundingBoxRect(
            left: minLeft,
            top: minTop,
            right: maxRight,
            bottom: maxBottom,
          ),
          cornerPoints: const [],
          expandRightEdge: !trimmedLast4,
        );
      }
    }

    final lineBox = line.boundingBox;
    if (lineBox == null || lineText.isEmpty) return null;

    final startFrac = (match.start / lineText.length).clamp(0.0, 1.0);
    final endFrac = (redactionEnd / lineText.length).clamp(0.0, 1.0);
    if (endFrac <= startFrac) return null;

    if (line.cornerPoints.length == 4) {
      final sliced = _sliceQuad(line.cornerPoints, startFrac, endFrac);
      final oriented = _orientUnionQuads([sliced], sliced);
      if (oriented != null) {
        return (
          box: oriented.box,
          cornerPoints: oriented.cornerPoints,
          expandRightEdge: !trimmedLast4,
        );
      }
    }

    return (
      box: BoundingBoxRect(
        left: lineBox.left + lineBox.width * startFrac,
        top: lineBox.top,
        right: lineBox.left + lineBox.width * endFrac,
        bottom: lineBox.bottom,
      ),
      cornerPoints: const [],
      expandRightEdge: !trimmedLast4,
    );
  }

  /// Linearly slices a 4-point oriented quad `[topLeft, topRight, bottomRight,
  /// bottomLeft]` along its reading direction for `[tStart, tEnd]` in `[0, 1]`.
  static List<({double x, double y})> _sliceQuad(
    List<CornerPoint> quad,
    double tStart,
    double tEnd,
  ) {
    final p0 = quad[0];
    final p1 = quad[1];
    final p2 = quad[2];
    final p3 = quad[3];
    return [
      (
        x: p0.x + (p1.x - p0.x) * tStart,
        y: p0.y + (p1.y - p0.y) * tStart,
      ),
      (
        x: p0.x + (p1.x - p0.x) * tEnd,
        y: p0.y + (p1.y - p0.y) * tEnd,
      ),
      (
        x: p3.x + (p2.x - p3.x) * tEnd,
        y: p3.y + (p2.y - p3.y) * tEnd,
      ),
      (
        x: p3.x + (p2.x - p3.x) * tStart,
        y: p3.y + (p2.y - p3.y) * tStart,
      ),
    ];
  }

  /// Unions [quads] inside the orthonormal `(u, v)` frame defined by
  /// [frameRef], returning both the tight oriented 4-corner polygon and its
  /// enclosing axis-aligned [BoundingBoxRect].
  static ({BoundingBoxRect box, List<CornerPoint> cornerPoints})?
      _orientUnionQuads(
    List<List<({double x, double y})>> quads,
    List<({double x, double y})> frameRef,
  ) {
    if (quads.isEmpty || frameRef.length < 4) return null;

    final dx = frameRef[1].x - frameRef[0].x;
    final dy = frameRef[1].y - frameRef[0].y;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1e-3) return null;

    final ux = dx / len;
    final uy = dy / len;
    var vx = -uy;
    var vy = ux;
    final hx = frameRef[3].x - frameRef[0].x;
    final hy = frameRef[3].y - frameRef[0].y;
    if (hx * vx + hy * vy < 0) {
      vx = -vx;
      vy = -vy;
    }

    var minU = double.infinity;
    var maxU = double.negativeInfinity;
    var minV = double.infinity;
    var maxV = double.negativeInfinity;

    for (final quad in quads) {
      for (final pt in quad) {
        final u = pt.x * ux + pt.y * uy;
        final v = pt.x * vx + pt.y * vy;
        if (u < minU) minU = u;
        if (u > maxU) maxU = u;
        if (v < minV) minV = v;
        if (v > maxV) maxV = v;
      }
    }

    if (!minU.isFinite || !maxU.isFinite || !minV.isFinite || !maxV.isFinite) {
      return null;
    }

    final cornersDouble = [
      (x: ux * minU + vx * minV, y: uy * minU + vy * minV),
      (x: ux * maxU + vx * minV, y: uy * maxU + vy * minV),
      (x: ux * maxU + vx * maxV, y: uy * maxU + vy * maxV),
      (x: ux * minU + vx * maxV, y: uy * minU + vy * maxV),
    ];

    final cornerPoints = cornersDouble
        .map((c) => CornerPoint(x: c.x.round(), y: c.y.round()))
        .toList();

    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (final c in cornersDouble) {
      if (c.x < minX) minX = c.x;
      if (c.y < minY) minY = c.y;
      if (c.x > maxX) maxX = c.x;
      if (c.y > maxY) maxY = c.y;
    }

    return (
      box: BoundingBoxRect(
        left: minX,
        top: minY,
        right: maxX,
        bottom: maxY,
      ),
      cornerPoints: cornerPoints,
    );
  }

  static Uint8List _burnRedactionsInIsolate({
    required Uint8List workingImageBytes,
    required List<_BurnRegionSpec> burnSpecs,
    required bool stripMetadata,
  }) {
    final decoded = img.decodeImage(workingImageBytes);
    if (decoded == null) {
      throw const ImagePayloadException(
        "Failed to decode working page during redaction burn-in.",
      );
    }

    final target = DocumentImageUtils.flattenToOpaqueRgb(decoded);
    if (stripMetadata) {
      target.exif.clear();
    }

    final maskColor = img.ColorRgb8(17, 22, 29);
    const pad = 2;

    for (final spec in burnSpecs) {
      final rightPad = spec.expandRightEdge ? pad : 0;
      final corners = spec.region.cornerPoints;

      if (corners.length >= 3) {
        final expanded = _expandPolygon(
          corners,
          leftPad: pad.toDouble(),
          rightPad: rightPad.toDouble(),
          verticalPad: pad.toDouble(),
          maxWidth: target.width - 1,
          maxHeight: target.height - 1,
        );
        if (expanded.length >= 3) {
          img.fillPolygon(
            target,
            vertices: expanded,
            blend: img.BlendMode.direct,
            color: maskColor,
          );
          continue;
        }
      }

      final rect = spec.region.boundingBox;
      final x1 = (rect.left.floor() - pad).clamp(0, target.width - 1);
      final y1 = (rect.top.floor() - pad).clamp(0, target.height - 1);
      final x2 = (rect.right.ceil() + rightPad).clamp(0, target.width - 1);
      final y2 = (rect.bottom.ceil() + pad).clamp(0, target.height - 1);
      if (x2 <= x1 || y2 <= y1) continue;

      img.fillRect(
        target,
        x1: x1,
        y1: y1,
        x2: x2,
        y2: y2,
        color: maskColor,
        alphaBlend: false,
      );
    }

    return Uint8List.fromList(img.encodePng(target));
  }

  /// Expands an oriented polygon outward along its reading and perpendicular
  /// axes, clamping all resulting vertices to image bounds.
  static List<img.Point> _expandPolygon(
    List<CornerPoint> corners, {
    required double leftPad,
    required double rightPad,
    required double verticalPad,
    required int maxWidth,
    required int maxHeight,
  }) {
    if (corners.length == 4) {
      final dx = (corners[1].x - corners[0].x).toDouble();
      final dy = (corners[1].y - corners[0].y).toDouble();
      final len = math.sqrt(dx * dx + dy * dy);
      if (len >= 1e-3) {
        final ux = dx / len;
        final uy = dy / len;
        var vx = -uy;
        var vy = ux;
        final hx = (corners[3].x - corners[0].x).toDouble();
        final hy = (corners[3].y - corners[0].y).toDouble();
        if (hx * vx + hy * vy < 0) {
          vx = -vx;
          vy = -vy;
        }

        final offsets = [
          (-leftPad, -verticalPad),
          (rightPad, -verticalPad),
          (rightPad, verticalPad),
          (-leftPad, verticalPad),
        ];
        final result = <img.Point>[];
        for (var i = 0; i < 4; i++) {
          final (du, dv) = offsets[i];
          final px = (corners[i].x + ux * du + vx * dv)
              .round()
              .clamp(0, maxWidth);
          final py = (corners[i].y + uy * du + vy * dv)
              .round()
              .clamp(0, maxHeight);
          result.add(img.Point(px, py));
        }
        return result;
      }
    }

    return corners
        .map(
          (c) => img.Point(
            c.x.clamp(0, maxWidth),
            c.y.clamp(0, maxHeight),
          ),
        )
        .toList();
  }

  static Future<Uint8List> _buildSanitizedPdfInIsolate({
    required List<_StagedSanitizedPage> pages,
    required PageNormalizationFormat pageFormat,
    required bool stripMetadata,
  }) async {
    final doc = PdfDocument(compress: true);
    if (!stripMetadata) {
      PdfInfo(doc, creator: "Droid Edge Server", producer: "Droid Edge Server");
    }
    final font = PdfFont.helvetica(doc);

    for (final pageData in pages) {
      final decoded = img.decodeImage(pageData.sanitizedPngBytes);
      if (decoded == null) {
        throw const ImagePayloadException(
          "Failed to decode sanitised page image for PDF assembly.",
        );
      }

      final jpegBytes = DocumentImageUtils.encodeCleanJpeg(
        decoded,
        quality: 86,
      );
      final resolvedFormat = DocumentImageUtils.resolvePdfPageFormat(
        pageFormat,
        pageData.width,
        pageData.height,
      );
      final pdfPage = PdfPage(doc, pageFormat: resolvedFormat);
      final graphics = pdfPage.getGraphics();
      final placement = DocumentImageUtils.computePagePlacement(
        resolvedFormat,
        pageData.width,
        pageData.height,
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
        ocr: pageData.sanitizedOcr,
        imgWidth: pageData.width,
        imgHeight: pageData.height,
        drawX: placement.drawX,
        drawY: placement.drawY,
        drawWidth: placement.drawWidth,
        drawHeight: placement.drawHeight,
      );
    }

    final stream = PdfStream();
    await doc.write(stream);
    return stream.output();
  }
}
