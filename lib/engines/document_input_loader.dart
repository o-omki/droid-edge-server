import "dart:convert";
import "dart:math" as math;
import "dart:typed_data";

import "package:image/image.dart" as img;
import "package:mime/mime.dart";

import "image_payload_processor.dart";
import "pdf_rasterizer.dart";

class DocumentInputLoader {
  const DocumentInputLoader._();

  /// Returns `true` when [bytes] starts with a standard `%PDF-` signature.
  static bool isPdfBytes(Uint8List bytes) {
    if (bytes.length < 5) return false;
    final headerSlice = bytes.sublist(0, math.min(32, bytes.length));
    final headerText = latin1.decode(headerSlice, allowInvalid: true);
    return headerText.contains("%PDF-");
  }

  /// Validates and expands [rawInputs] (images and/or PDF documents) into an
  /// ordered list of per-page encoded image byte buffers.
  static Future<List<Uint8List>> expandToPageBytes(
    List<Uint8List> rawInputs, {
    required PdfRasterizer pdfRasterizer,
  }) async {
    if (rawInputs.isEmpty) {
      throw const ImagePayloadException("No document or image payloads found.");
    }

    final pageBytesList = <Uint8List>[];
    for (final input in rawInputs) {
      if (input.isEmpty) {
        throw const ImagePayloadException(
          "Uploaded document payload is empty.",
        );
      }
      if (isPdfBytes(input)) {
        final rasterPages = await pdfRasterizer.rasterizePdf(input);
        for (final page in rasterPages) {
          pageBytesList.add(page.imageBytes);
        }
      } else {
        _validateImageBytes(input);
        pageBytesList.add(input);
      }
    }

    if (pageBytesList.isEmpty) {
      throw const ImagePayloadException(
        "No valid pages could be extracted from the uploaded document.",
      );
    }
    return pageBytesList;
  }

  /// Loads [rawInputs] sequentially into staged [PreparedImagePayload] files.
  ///
  /// Callers must call `cleanup()` on each returned payload once finished.
  static Future<List<PreparedImagePayload>> loadAsPreparedPages(
    List<Uint8List> rawInputs, {
    required PdfRasterizer pdfRasterizer,
  }) async {
    final pageBytes = await expandToPageBytes(
      rawInputs,
      pdfRasterizer: pdfRasterizer,
    );
    final staged = <PreparedImagePayload>[];
    try {
      for (final bytes in pageBytes) {
        staged.add(await ImagePayloadProcessor.prepareFromBytes(bytes));
      }
      return staged;
    } catch (_) {
      for (final item in staged) {
        await item.cleanup();
      }
      rethrow;
    }
  }

  static void _validateImageBytes(Uint8List bytes) {
    final headerLen = bytes.length < 32 ? bytes.length : 32;
    final detectedMime = lookupMimeType(
      "",
      headerBytes: bytes.sublist(0, headerLen),
    );
    final decoder = img.findDecoderForData(bytes);
    final isSupportedMime =
        detectedMime != null && detectedMime.startsWith("image/");
    if (!isSupportedMime && decoder == null) {
      throw const ImagePayloadException(
        "Unsupported or corrupted document/image payload. Expected an image "
        "(JPEG, PNG, WebP) or PDF file.",
      );
    }
  }
}
