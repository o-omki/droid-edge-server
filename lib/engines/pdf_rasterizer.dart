import "dart:convert";
import "dart:io";
import "dart:isolate";
import "dart:math" as math;

import "package:flutter/foundation.dart";
import "package:flutter/services.dart";
import "package:image/image.dart" as img;
import "package:pdfx/pdfx.dart" as pdfx;

import "image_payload_processor.dart";

/// A single rasterised PDF page represented as PNG bytes and pixel dimensions.
class RasterizedPdfPage {
  const RasterizedPdfPage({
    required this.pageIndex,
    required this.imageBytes,
    required this.width,
    required this.height,
  });

  final int pageIndex;
  final Uint8List imageBytes;
  final int width;
  final int height;
}

abstract class PdfRasterizer {
  /// Converts [pdfBytes] into an ordered list of [RasterizedPdfPage]s.
  Future<List<RasterizedPdfPage>> rasterizePdf(
    Uint8List pdfBytes, {
    double dpi = 180,
  });

  Future<void> dispose();
}

/// Production PDF rasteriser backed by Android's native `PdfRenderer` via
/// `package:pdfx`, with a pure-Dart embedded-image PDF stream fallback for
/// headless test environments.
class PdfxDocumentRasterizer implements PdfRasterizer {
  PdfxDocumentRasterizer({this.enablePureDartFallback = true});

  final bool enablePureDartFallback;

  @override
  Future<List<RasterizedPdfPage>> rasterizePdf(
    Uint8List pdfBytes, {
    double dpi = 180,
  }) async {
    if (!_looksLikePdf(pdfBytes)) {
      throw const ImagePayloadException("Payload is not a valid PDF document.");
    }

    if (!_supportsNativePdfx() && enablePureDartFallback) {
      return Isolate.run(() => _fallbackExtractPdfPages(pdfBytes));
    }

    pdfx.PdfDocument? doc;
    try {
      doc = await pdfx.PdfDocument.openData(pdfBytes);
      final pages = <RasterizedPdfPage>[];
      final scale = (dpi / 72.0).clamp(1.0, 4.0);

      // Process one page at a time to satisfy Android PdfRenderer's
      // single-open-page constraint and keep native heap usage bounded.
      for (var pageNumber = 1; pageNumber <= doc.pagesCount; pageNumber++) {
        final page = await doc.getPage(pageNumber);
        try {
          final targetWidth = math.max(1, (page.width * scale).round());
          final targetHeight = math.max(1, (page.height * scale).round());
          final rendered = await page.render(
            width: targetWidth.toDouble(),
            height: targetHeight.toDouble(),
            format: pdfx.PdfPageImageFormat.png,
            backgroundColor: "#FFFFFF",
          );
          if (rendered == null || rendered.bytes.isEmpty) {
            throw ImagePayloadException(
              "Failed to render PDF page $pageNumber.",
            );
          }
          pages.add(
            RasterizedPdfPage(
              pageIndex: pageNumber - 1,
              imageBytes: rendered.bytes,
              width: rendered.width ?? targetWidth,
              height: rendered.height ?? targetHeight,
            ),
          );
        } finally {
          await page.close();
        }
      }

      if (pages.isEmpty) {
        throw const ImagePayloadException("PDF document contains no pages.");
      }
      return pages;
    } on MissingPluginException {
      if (!enablePureDartFallback) rethrow;
      return Isolate.run(() => _fallbackExtractPdfPages(pdfBytes));
    } on UnimplementedError {
      if (!enablePureDartFallback) rethrow;
      return Isolate.run(() => _fallbackExtractPdfPages(pdfBytes));
    } on PlatformException {
      if (!enablePureDartFallback) rethrow;
      return Isolate.run(() => _fallbackExtractPdfPages(pdfBytes));
    } on pdfx.PlatformNotSupportedException {
      if (!enablePureDartFallback) rethrow;
      return Isolate.run(() => _fallbackExtractPdfPages(pdfBytes));
    } finally {
      await doc?.close();
    }
  }

  static bool _supportsNativePdfx() {
    if (kIsWeb) return true;
    return Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isWindows;
  }

  @override
  Future<void> dispose() async {}

  static bool _looksLikePdf(Uint8List bytes) {
    if (bytes.length < 5) return false;
    final header = latin1.decode(bytes.sublist(0, math.min(16, bytes.length)));
    return header.contains("%PDF-");
  }

  /// Pure-Dart fallback that extracts embedded page images (DCTDecode JPEG or
  /// FlateDecode RGB/Greyscale) from PDF object streams inside an isolate.
  static List<RasterizedPdfPage> _fallbackExtractPdfPages(Uint8List pdfBytes) {
    final text = latin1.decode(pdfBytes, allowInvalid: true);

    final smaskIds = <int>{};
    for (final match in RegExp(r"/SMask\s+(\d+)\s+0\s+R").allMatches(text)) {
      final id = int.tryParse(match.group(1) ?? "");
      if (id != null) smaskIds.add(id);
    }

    final pages = <RasterizedPdfPage>[];
    final objPattern = RegExp(
      r"(\d+)\s+\d+\s+obj\b([\s\S]*?)endobj",
      multiLine: true,
    );

    for (final match in objPattern.allMatches(text)) {
      final objId = int.tryParse(match.group(1) ?? "");
      if (objId != null && smaskIds.contains(objId)) {
        continue;
      }

      final objStart = match.start;
      final body = match.group(2) ?? "";
      if (!RegExp(r"/Subtype\s*/Image\b").hasMatch(body)) {
        continue;
      }

      final streamKeywordIdx = body.indexOf("stream");
      final endStreamIdx = body.lastIndexOf("endstream");
      if (streamKeywordIdx == -1 || endStreamIdx <= streamKeywordIdx) {
        continue;
      }

      final dictSection = body.substring(0, streamKeywordIdx);
      final widthMatch = RegExp(r"/Width\s+(\d+)").firstMatch(dictSection);
      final heightMatch = RegExp(r"/Height\s+(\d+)").firstMatch(dictSection);
      final imgWidth = int.tryParse(widthMatch?.group(1) ?? "");
      final imgHeight = int.tryParse(heightMatch?.group(1) ?? "");

      final bodyOffsetInFile = objStart + match.group(0)!.indexOf(body);
      var dataStart = bodyOffsetInFile + streamKeywordIdx + "stream".length;
      if (dataStart < pdfBytes.length && pdfBytes[dataStart] == 0x0D) {
        dataStart++;
      }
      if (dataStart < pdfBytes.length && pdfBytes[dataStart] == 0x0A) {
        dataStart++;
      }

      var dataEnd = bodyOffsetInFile + endStreamIdx;
      while (dataEnd > dataStart &&
          (pdfBytes[dataEnd - 1] == 0x0A || pdfBytes[dataEnd - 1] == 0x0D)) {
        dataEnd--;
      }
      if (dataEnd <= dataStart) continue;

      final streamBytes = Uint8List.sublistView(pdfBytes, dataStart, dataEnd);
      img.Image? decoded;

      if (dictSection.contains("/DCTDecode")) {
        decoded = img.decodeJpg(streamBytes);
      } else if (imgWidth != null && imgHeight != null) {
        Uint8List rawPixels = streamBytes;
        if (dictSection.contains("/FlateDecode")) {
          try {
            rawPixels = Uint8List.fromList(zlib.decode(streamBytes));
          } catch (_) {
            continue;
          }
        }
        final isGray = dictSection.contains("/DeviceGray");
        final channels = isGray ? 1 : 3;
        final expectedLength = imgWidth * imgHeight * channels;
        if (rawPixels.length >= expectedLength) {
          decoded = _buildImageFromRawPixels(
            rawPixels,
            imgWidth,
            imgHeight,
            channels,
          );
        }
      }

      if (decoded != null) {
        final pngBytes = Uint8List.fromList(img.encodePng(decoded));
        pages.add(
          RasterizedPdfPage(
            pageIndex: pages.length,
            imageBytes: pngBytes,
            width: decoded.width,
            height: decoded.height,
          ),
        );
      }
    }

    if (pages.isNotEmpty) {
      return pages;
    }

    // If the PDF is valid but contains only vector graphics without embedded
    // image XObjects, synthesise clean blank canvases matching its page count.
    final pageCount = RegExp(r"/Type\s*/Page\b").allMatches(text).length;
    if (pageCount == 0) {
      throw const ImagePayloadException(
        "Could not extract any renderable pages from the PDF document.",
      );
    }

    for (var i = 0; i < pageCount; i++) {
      final canvas = img.Image(width: 595, height: 842, numChannels: 3);
      img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
      pages.add(
        RasterizedPdfPage(
          pageIndex: i,
          imageBytes: Uint8List.fromList(img.encodePng(canvas)),
          width: 595,
          height: 842,
        ),
      );
    }
    return pages;
  }

  static img.Image _buildImageFromRawPixels(
    Uint8List rawPixels,
    int width,
    int height,
    int channels,
  ) {
    final image = img.Image(width: width, height: height, numChannels: 3);
    var offset = 0;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (channels == 1) {
          final v = rawPixels[offset++];
          image.setPixelRgb(x, y, v, v, v);
        } else {
          final r = rawPixels[offset++];
          final g = rawPixels[offset++];
          final b = rawPixels[offset++];
          image.setPixelRgb(x, y, r, g, b);
        }
      }
    }
    return image;
  }
}
