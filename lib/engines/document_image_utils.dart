import "dart:math" as math;
import "dart:typed_data";

import "package:image/image.dart" as img;
import "package:pdf/pdf.dart";

import "../models/document_pipeline_models.dart";
import "../models/geometry_models.dart";
import "../models/ocr_result.dart";
import "image_payload_processor.dart";

/// Normalised single-page raster data ready for OCR and PDF/redaction assembly.
class PreprocessedPageData {
  const PreprocessedPageData({
    required this.workingImageBytes,
    required this.width,
    required this.height,
    this.originalPreviewBytes,
  });

  final Uint8List workingImageBytes;
  final Uint8List? originalPreviewBytes;
  final int width;
  final int height;
}

/// Shared isolate-safe image cleanup, metadata stripping, and invisible PDF
/// text layer utilities used by both [SearchablePdfEngine] and
/// [PiiRedactionEngine].
class DocumentImageUtils {
  const DocumentImageUtils._();

  /// Decodes [rawBytes], bakes EXIF orientation, flattens alpha onto white,
  /// strips EXIF/GPS metadata, and optionally applies contrast/brightness
  /// enhancement.
  static PreprocessedPageData preprocessPage(
    Uint8List rawBytes, {
    required bool enhanceContrast,
    double contrast = 1.18,
    double brightness = 1.02,
    bool captureOriginalPreview = false,
  }) {
    final decoded = img.decodeImage(rawBytes);
    if (decoded == null) {
      throw const ImagePayloadException(
        "Failed to decode page image payload.",
      );
    }

    final oriented = img.bakeOrientation(decoded);
    final opaque = _flattenToOpaqueRgb(oriented);
    opaque.exif.clear();

    Uint8List? originalPreviewBytes;
    if (captureOriginalPreview) {
      originalPreviewBytes = Uint8List.fromList(
        img.encodeJpg(opaque, quality: 86),
      );
    }

    var working = opaque;
    if (enhanceContrast) {
      working = img.adjustColor(
        img.Image.from(opaque),
        contrast: contrast.clamp(0.5, 2.5),
        brightness: brightness.clamp(0.5, 2.0),
      );
      working.exif.clear();
    }

    final workingBytes = Uint8List.fromList(img.encodePng(working));
    return PreprocessedPageData(
      workingImageBytes: workingBytes,
      originalPreviewBytes: originalPreviewBytes,
      width: working.width,
      height: working.height,
    );
  }

  /// Flattens transparent pixels onto a pure white background and ensures an
  /// opaque 3-channel RGB image free of alpha artefacts.
  static img.Image flattenToOpaqueRgb(img.Image source) =>
      _flattenToOpaqueRgb(source);

  static img.Image _flattenToOpaqueRgb(img.Image source) {
    if (!source.hasAlpha && source.numChannels == 3) {
      return img.Image.from(source);
    }
    final out = img.Image(
      width: source.width,
      height: source.height,
      numChannels: 3,
    );
    final maxAlpha = source.maxChannelValue;
    for (var y = 0; y < source.height; y++) {
      for (var x = 0; x < source.width; x++) {
        final pixel = source.getPixel(x, y);
        final alpha =
            source.hasAlpha ? (pixel.a / maxAlpha).clamp(0.0, 1.0) : 1.0;
        final invAlpha = 1.0 - alpha;
        final r = (pixel.rNormalized * 255.0 * alpha + 255.0 * invAlpha).round();
        final g = (pixel.gNormalized * 255.0 * alpha + 255.0 * invAlpha).round();
        final b = (pixel.bNormalized * 255.0 * alpha + 255.0 * invAlpha).round();
        out.setPixelRgb(
          x,
          y,
          r.clamp(0, 255),
          g.clamp(0, 255),
          b.clamp(0, 255),
        );
      }
    }
    return out;
  }

  /// Resizes [source] by [scaleFactor] (if `< 1.0`) and encodes a metadata-free
  /// JPEG at [quality].
  static Uint8List encodeCleanJpeg(
    img.Image source, {
    required int quality,
    double scaleFactor = 1.0,
  }) {
    var target = source;
    if (scaleFactor < 0.999) {
      final targetWidth = math.max(1, (source.width * scaleFactor).round());
      final targetHeight = math.max(1, (source.height * scaleFactor).round());
      target = img.copyResize(
        source,
        width: targetWidth,
        height: targetHeight,
        interpolation: img.Interpolation.linear,
      );
    }
    target.exif.clear();
    return Uint8List.fromList(img.encodeJpg(target, quality: quality));
  }

  /// Resolves the PDF page dimensions for [format], matching the orientation of
  /// an image with [imgWidth] × [imgHeight].
  static PdfPageFormat resolvePdfPageFormat(
    PageNormalizationFormat format,
    int imgWidth,
    int imgHeight,
  ) {
    final isLandscape = imgWidth > imgHeight;
    switch (format) {
      case PageNormalizationFormat.a4:
        return isLandscape
            ? PdfPageFormat.a4.landscape.copyWith(
                marginTop: 0,
                marginBottom: 0,
                marginLeft: 0,
                marginRight: 0,
              )
            : PdfPageFormat.a4.copyWith(
                marginTop: 0,
                marginBottom: 0,
                marginLeft: 0,
                marginRight: 0,
              );
      case PageNormalizationFormat.letter:
        return isLandscape
            ? PdfPageFormat.letter.landscape.copyWith(
                marginTop: 0,
                marginBottom: 0,
                marginLeft: 0,
                marginRight: 0,
              )
            : PdfPageFormat.letter.copyWith(
                marginTop: 0,
                marginBottom: 0,
                marginLeft: 0,
                marginRight: 0,
              );
      case PageNormalizationFormat.original:
        return PdfPageFormat(
          math.max(1.0, imgWidth.toDouble()),
          math.max(1.0, imgHeight.toDouble()),
          marginAll: 0,
        );
    }
  }

  /// Computes an aspect-ratio-preserving centred image rectangle inside
  /// [pageFormat].
  static ({double drawX, double drawY, double drawWidth, double drawHeight})
      computePagePlacement(
    PdfPageFormat pageFormat,
    int imgWidth,
    int imgHeight,
  ) {
    final safeW = math.max(1.0, imgWidth.toDouble());
    final safeH = math.max(1.0, imgHeight.toDouble());
    final scale = math.min(
      pageFormat.width / safeW,
      pageFormat.height / safeH,
    );
    final drawWidth = safeW * scale;
    final drawHeight = safeH * scale;
    final drawX = (pageFormat.width - drawWidth) / 2.0;
    final drawY = (pageFormat.height - drawHeight) / 2.0;
    return (
      drawX: drawX,
      drawY: drawY,
      drawWidth: drawWidth,
      drawHeight: drawHeight,
    );
  }

  /// Renders an invisible (`3 Tr` / [PdfTextRenderingMode.invisible]) OCR text
  /// layer aligned to the visual page image coordinates.
  static void drawInvisibleOcrTextLayer({
    required PdfGraphics graphics,
    required PdfFont font,
    required OcrResult ocr,
    required int imgWidth,
    required int imgHeight,
    required double drawX,
    required double drawY,
    required double drawWidth,
    required double drawHeight,
  }) {
    if (imgWidth <= 0 || imgHeight <= 0) return;
    final scaleX = drawWidth / imgWidth;
    final scaleY = drawHeight / imgHeight;
    var drewAnySegment = false;

    for (final block in ocr.blocks) {
      for (final line in block.lines) {
        if (line.elements.isNotEmpty) {
          for (var i = 0; i < line.elements.length; i++) {
            final element = line.elements[i];
            final box = element.boundingBox;
            final cleanText = sanitisePdfText(element.text);
            if (box == null || cleanText.isEmpty) continue;

            final token =
                i < line.elements.length - 1 ? "$cleanText " : cleanText;
            _drawBoxedInvisibleText(
              graphics: graphics,
              font: font,
              displayText: token,
              widthReferenceText: cleanText,
              box: box,
              imgWidth: imgWidth,
              imgHeight: imgHeight,
              drawX: drawX,
              drawY: drawY,
              scaleX: scaleX,
              scaleY: scaleY,
            );
            drewAnySegment = true;
          }
        } else {
          final box = line.boundingBox;
          final cleanText = sanitisePdfText(line.text);
          if (box == null || cleanText.isEmpty) continue;
          _drawBoxedInvisibleText(
            graphics: graphics,
            font: font,
            displayText: cleanText,
            widthReferenceText: cleanText,
            box: box,
            imgWidth: imgWidth,
            imgHeight: imgHeight,
            drawX: drawX,
            drawY: drawY,
            scaleX: scaleX,
            scaleY: scaleY,
          );
          drewAnySegment = true;
        }
      }
    }

    if (!drewAnySegment) {
      final fallback = sanitisePdfText(ocr.text);
      if (fallback.isNotEmpty) {
        graphics.drawString(
          font,
          10.0,
          fallback,
          drawX + 8.0,
          drawY + drawHeight - 18.0,
          mode: PdfTextRenderingMode.invisible,
        );
      }
    }
  }

  static void _drawBoxedInvisibleText({
    required PdfGraphics graphics,
    required PdfFont font,
    required String displayText,
    required String widthReferenceText,
    required BoundingBoxRect box,
    required int imgWidth,
    required int imgHeight,
    required double drawX,
    required double drawY,
    required double scaleX,
    required double scaleY,
  }) {
    final left = box.left.clamp(0.0, imgWidth.toDouble());
    final bottom = box.bottom.clamp(0.0, imgHeight.toDouble());
    final pdfX = drawX + left * scaleX;
    final pdfBottom = drawY + (imgHeight - bottom) * scaleY;
    final pdfWidth = math.max(1.0, box.width * scaleX);
    final pdfHeight = math.max(2.0, box.height * scaleY);

    final fontSize = (pdfHeight / 1.12).clamp(3.0, 72.0);
    final baselineY = pdfBottom + fontSize * 0.18;

    final metrics = font.stringMetrics(widthReferenceText);
    final naturalWidth = math.max(0.5, metrics.width * fontSize);
    final horizontalScale = (pdfWidth / naturalWidth).clamp(0.25, 4.0);

    graphics.drawString(
      font,
      fontSize,
      displayText,
      pdfX,
      baselineY,
      scale: horizontalScale,
      mode: PdfTextRenderingMode.invisible,
    );
  }

  /// Normalises [raw] to WinAnsi/Latin-1 printable characters accepted by PDF
  /// standard Type1 Helvetica.
  static String sanitisePdfText(String raw) {
    if (raw.isEmpty) return "";
    final buffer = StringBuffer();
    for (final rune in raw.runes) {
      switch (rune) {
        case 0x2018:
        case 0x2019:
          buffer.write("'");
          break;
        case 0x201C:
        case 0x201D:
          buffer.write("\"");
          break;
        case 0x2013:
        case 0x2014:
          buffer.write("-");
          break;
        case 0x2022:
          buffer.write("*");
          break;
        case 0x0A:
        case 0x0D:
        case 0x09:
          buffer.write(" ");
          break;
        default:
          if (rune >= 0x20 && rune <= 0x7E) {
            buffer.writeCharCode(rune);
          } else if (rune >= 0xA0 && rune <= 0xFF) {
            buffer.writeCharCode(rune);
          } else {
            buffer.write("?");
          }
          break;
      }
    }
    return buffer.toString().trim();
  }
}
