import "dart:convert";
import "dart:isolate";
import "dart:typed_data";

import "package:archive/archive.dart";

/// A single output entry to be packaged into a `.zip` archive.
class BatchArchiveEntry {
  const BatchArchiveEntry({
    required this.filename,
    required this.bytes,
    this.metadata = const {},
  });

  final String filename;
  final Uint8List bytes;
  final Map<String, dynamic> metadata;
}

/// Packages sequential batch document outputs and a `manifest.json` summary
/// into a `.zip` buffer inside a background isolate.
class BatchZipEngine {
  const BatchZipEngine._();

  /// Encodes [entries] and an optional [manifestSummary] into a compressed ZIP
  /// byte buffer inside `Isolate.run`.
  static Future<Uint8List> buildZip(
    List<BatchArchiveEntry> entries, {
    Map<String, dynamic> manifestSummary = const {},
  }) {
    return Isolate.run(() {
      final archive = Archive();
      final usedNames = <String>{};
      final manifestItems = <Map<String, dynamic>>[];

      for (var i = 0; i < entries.length; i++) {
        final entry = entries[i];
        final uniqueName = _deduplicateName(
          _sanitiseFilename(entry.filename, fallbackIndex: i + 1),
          usedNames,
        );
        usedNames.add(uniqueName);

        archive.addFile(ArchiveFile.bytes(uniqueName, entry.bytes));
        manifestItems.add({
          "filename": uniqueName,
          "byte_length": entry.bytes.length,
          ...entry.metadata,
        });
      }

      final manifestPayload = const JsonEncoder.withIndent("  ").convert({
        "generated_at": DateTime.now().toUtc().toIso8601String(),
        "item_count": entries.length,
        ...manifestSummary,
        "items": manifestItems,
      });
      archive.addFile(ArchiveFile.string("manifest.json", manifestPayload));

      return ZipEncoder().encodeBytes(archive);
    });
  }

  static String _sanitiseFilename(String raw, {required int fallbackIndex}) {
    final base = raw.split(RegExp(r"[\\/]")).last.trim();
    final cleaned = base.replaceAll(RegExp(r"[^A-Za-z0-9._\-]"), "_");
    if (cleaned.isEmpty || cleaned == "." || cleaned == "..") {
      return "document_$fallbackIndex.bin";
    }
    return cleaned;
  }

  static String _deduplicateName(String candidate, Set<String> usedNames) {
    if (!usedNames.contains(candidate)) {
      return candidate;
    }
    final dotIdx = candidate.lastIndexOf(".");
    final stem = dotIdx > 0 ? candidate.substring(0, dotIdx) : candidate;
    final ext = dotIdx > 0 ? candidate.substring(dotIdx) : "";
    var suffix = 2;
    while (usedNames.contains("${stem}_$suffix$ext")) {
      suffix++;
    }
    return "${stem}_$suffix$ext";
  }
}
