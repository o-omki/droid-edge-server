import "dart:isolate";
import "dart:math" as math;
import "dart:typed_data";

import "package:image/image.dart" as img;
import "package:pdf/pdf.dart";

import "../models/document_pipeline_models.dart";
import "../models/geometry_models.dart";
import "../models/ocr_result.dart";
import "document_image_utils.dart";
import "document_input_loader.dart";
import "face_detection_engine.dart";
import "image_payload_processor.dart";
import "ocr_engine.dart";
import "pdf_rasterizer.dart";

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
  });

  final String category;
  final int start;
  final int end;
  final String matchedText;
  final bool supportsKeepLast4;
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
  });

  final OcrEngine ocrEngine;
  final FaceDetectionEngine faceDetectionEngine;
  final PdfRasterizer pdfRasterizer;

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
  static final RegExp _ifscRegex = RegExp(r"\b[A-Z]{4}0[A-Z0-9]{6}\b");
  static final RegExp _ibanRegex = RegExp(r"\b[A-Z]{2}\d{2}[A-Z0-9]{10,28}\b");
  static final RegExp _labeledIdRegex = RegExp(
    r"(?:\b(?:ID|ID\s*#|SSN|SIN|TIN|EIN|Tax\s*ID|Account|Acct|Acc|Card|Policy|License|Licence|DL|Passport|Member\s*ID|Customer\s*ID|Aadhaar|Aadhar|UID|VID|PAN|GSTIN|GST|EPIC|Voter\s*ID|PRAN|UAN|IFSC|CIF|CKYC|ABHA|Ayushman)\b|(?:आधार|पैन|पहचान))(?:\s*(?:No|Num|Number|संख्या|#))?\s*[:#\-]?\s*(?=[A-Z0-9\-]*\d)([A-Z0-9][A-Z0-9\-]{4,24})",
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
    r"(?:\b(?:Address|Addr|Residence|Location)\b|पता)\s*[:\-]\s*(.+)$",
    caseSensitive: false,
  );
  static final RegExp _streetAddressRegex = RegExp(
    r"\b\d{1,6}\s+(?:[A-Za-z0-9.#\-]+\s+){1,5}(?:Street|St|Avenue|Ave|Road|Rd|Boulevard|Blvd|Lane|Ln|Drive|Dr|Court|Ct|Way|Parkway|Pkwy|Circle|Cir|Place|Pl|Terrace|Ter|Square|Sq)\b\.?(?:[,\s]+[A-Za-z0-9\s,\-]{2,40})?",
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
      List<BoundingBoxRect> faceBoxes = const [];
      try {
        ocr = await ocrEngine.processImage(
          stagedPayload,
          script: options.script,
        );
        if (options.presets.contains(RedactionPreset.faces)) {
          faceBoxes = await faceDetectionEngine.detectFaces(stagedPayload);
        }
      } finally {
        await stagedPayload.cleanup();
      }

      final detection = _detectPageRedactions(
        ocr: ocr,
        faceBoxes: faceBoxes,
        pageIndex: pageIndex,
        options: options,
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
    required List<BoundingBoxRect> faceBoxes,
    required int pageIndex,
    required RedactionOptions options,
  }) {
    final burnSpecs = <_BurnRegionSpec>[];
    final sanitizedBlocks = <OcrTextBlock>[];

    for (final block in ocr.blocks) {
      final sanitizedLines = <OcrTextLine>[];

      for (final line in block.lines) {
        final lineData = _resolveLineSpans(line);
        final candidates = _findLineCandidates(
          lineText: lineData.text,
          presets: options.presets,
        );

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

    for (final faceBox in faceBoxes) {
      burnSpecs.add(
        _BurnRegionSpec(
          region: RedactedRegion(
            pageIndex: pageIndex,
            category: "face",
            boundingBox: faceBox,
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

    return _deduplicateCandidates(candidates);
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
      return "[REDACTED ID]";
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

  /// Resolves the exact pixel bounding box covering the redacted slice of
  /// [match], excluding the final 4 characters when [keepLast4] is enabled.
  static ({BoundingBoxRect box, bool expandRightEdge})? _computeMatchBox({
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

        final sliceLeft = box.left + (box.width * (localStart / elemLen));
        final sliceRight = box.left + (box.width * (localEnd / elemLen));

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
        return (
          box: BoundingBoxRect(
            left: minLeft,
            top: minTop,
            right: maxRight,
            bottom: maxBottom,
          ),
          expandRightEdge: !trimmedLast4,
        );
      }
    }

    final lineBox = line.boundingBox;
    if (lineBox == null || lineText.isEmpty) return null;

    final startFrac = (match.start / lineText.length).clamp(0.0, 1.0);
    final endFrac = (redactionEnd / lineText.length).clamp(0.0, 1.0);
    if (endFrac <= startFrac) return null;

    return (
      box: BoundingBoxRect(
        left: lineBox.left + lineBox.width * startFrac,
        top: lineBox.top,
        right: lineBox.left + lineBox.width * endFrac,
        bottom: lineBox.bottom,
      ),
      expandRightEdge: !trimmedLast4,
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
      final rect = spec.region.boundingBox;
      final x1 = (rect.left.floor() - pad).clamp(0, target.width - 1);
      final y1 = (rect.top.floor() - pad).clamp(0, target.height - 1);
      final rightPad = spec.expandRightEdge ? pad : 0;
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
