import "dart:math" as math;

import "../models/geometry_models.dart";
import "../models/ocr_result.dart";
import "../models/openai_vision_models.dart";

class _PositionedCell {
  const _PositionedCell({
    required this.text,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;

  double get centerY => (top + bottom) / 2.0;
  double get centerX => (left + right) / 2.0;
  double get width => math.max(1.0, right - left);
  double get height => math.max(1.0, bottom - top);
}

class _ColumnTrack {
  _ColumnTrack({
    required this.left,
    required this.right,
  });

  double left;
  double right;

  double get centerX => (left + right) / 2.0;

  void expandTo(double cellLeft, double cellRight) {
    left = math.min(left, cellLeft);
    right = math.max(right, cellRight);
  }
}

/// Tier 1 deterministic 2D spatial bounding-box table reconstructor.
///
/// Reuses [BoundingBoxRect] coordinates produced by ML Kit Text Recognition v2
/// to cluster OCR elements into horizontal rows and X-aligned columns,
/// emitting GitHub-Flavoured Markdown tables without external model downloads.
class SpatialTableReconstructor {
  const SpatialTableReconstructor._();

  static final RegExp _numericCellRegex = RegExp(
    r"^[+-]?(?:[$€£¥₹]|USD|EUR|GBP|INR|Rs\.?)?\s*[\d,]+(?:\.\d+)?\s*%?$",
    caseSensitive: false,
  );

  static final RegExp _keyValueRegex = RegExp(
    r"^([A-Za-z0-9][A-Za-z0-9\s.#/\-()]{1,40}):\s+(.+)$",
  );

  /// Reconstructs a [SpatialTableResult] from [ocr].
  static SpatialTableResult reconstruct(OcrResult ocr) {
    final cells = _extractCells(ocr);
    if (cells.isEmpty) {
      return _reconstructFromPlainText(ocr.text);
    }

    final heights = cells.map((c) => c.height).toList()..sort();
    final medianHeight = heights.isEmpty
        ? 20.0
        : heights[heights.length ~/ 2];
    final rowTolerance = math.max(8.0, 0.52 * medianHeight);

    final rowClusters = _clusterRows(cells, rowTolerance: rowTolerance);
    if (rowClusters.isEmpty) {
      return _reconstructFromPlainText(ocr.text);
    }

    final tracks = _discoverColumnTracks(
      rowClusters,
      medianHeight: medianHeight,
    );

    if (tracks.length <= 1) {
      final fallback = _tryKeyValueOrWhitespaceFallback(rowClusters);
      if (fallback != null) {
        return fallback;
      }
    }

    final columnCount = math.max(1, tracks.length);
    final matrix = <List<String>>[];

    for (final row in rowClusters) {
      final rowValues = List<String>.filled(columnCount, "");
      for (final cell in row) {
        final colIndex = _assignColumnIndex(cell, tracks);
        final existing = rowValues[colIndex];
        rowValues[colIndex] = existing.isEmpty
            ? cell.text
            : "$existing ${cell.text}";
      }
      if (rowValues.any((value) => value.trim().isNotEmpty)) {
        matrix.add(rowValues);
      }
    }

    if (matrix.isEmpty) {
      return _reconstructFromPlainText(ocr.text);
    }

    return _buildTableResult(matrix);
  }

  static List<_PositionedCell> _extractCells(OcrResult ocr) {
    final collected = <_PositionedCell>[];

    // Pre-compute median element height so same-line cell merging adapts to scale.
    final rawElementHeights = <double>[];
    for (final block in ocr.blocks) {
      for (final line in block.lines) {
        if (line.elements.isNotEmpty) {
          for (final element in line.elements) {
            final box = element.boundingBox;
            if (box != null && box.height > 0) {
              rawElementHeights.add(box.height);
            }
          }
        } else if (line.boundingBox != null && line.boundingBox!.height > 0) {
          rawElementHeights.add(line.boundingBox!.height);
        }
      }
    }
    rawElementHeights.sort();
    final medianElementHeight = rawElementHeights.isEmpty
        ? 20.0
        : rawElementHeights[rawElementHeights.length ~/ 2];
    final inlineGapThreshold = math.max(12.0, 0.85 * medianElementHeight);

    for (final block in ocr.blocks) {
      for (final line in block.lines) {
        final positionedElements = line.elements
            .where((e) => e.text.trim().isNotEmpty && e.boundingBox != null)
            .toList();

        if (positionedElements.isNotEmpty) {
          positionedElements.sort(
            (a, b) => a.boundingBox!.left.compareTo(b.boundingBox!.left),
          );

          var currentText = positionedElements.first.text.trim();
          var box = positionedElements.first.boundingBox!;
          var curLeft = box.left;
          var curTop = box.top;
          var curRight = box.right;
          var curBottom = box.bottom;

          for (var i = 1; i < positionedElements.length; i++) {
            final next = positionedElements[i];
            final nextBox = next.boundingBox!;
            final gap = nextBox.left - curRight;
            if (gap <= inlineGapThreshold) {
              currentText = "$currentText ${next.text.trim()}";
              curLeft = math.min(curLeft, nextBox.left);
              curTop = math.min(curTop, nextBox.top);
              curRight = math.max(curRight, nextBox.right);
              curBottom = math.max(curBottom, nextBox.bottom);
            } else {
              collected.add(
                _PositionedCell(
                  text: currentText,
                  left: curLeft,
                  top: curTop,
                  right: curRight,
                  bottom: curBottom,
                ),
              );
              currentText = next.text.trim();
              curLeft = nextBox.left;
              curTop = nextBox.top;
              curRight = nextBox.right;
              curBottom = nextBox.bottom;
            }
          }

          collected.add(
            _PositionedCell(
              text: currentText,
              left: curLeft,
              top: curTop,
              right: curRight,
              bottom: curBottom,
            ),
          );
          continue;
        }

        final lineBox = line.boundingBox;
        final trimmed = line.text.trim();
        if (trimmed.isEmpty) continue;
        if (lineBox != null) {
          collected.add(
            _PositionedCell(
              text: trimmed,
              left: lineBox.left,
              top: lineBox.top,
              right: lineBox.right,
              bottom: lineBox.bottom,
            ),
          );
        }
      }
    }

    return collected;
  }

  static List<List<_PositionedCell>> _clusterRows(
    List<_PositionedCell> cells, {
    required double rowTolerance,
  }) {
    final sorted = List<_PositionedCell>.from(cells)
      ..sort((a, b) => a.centerY.compareTo(b.centerY));

    final rows = <List<_PositionedCell>>[];
    final rowMeans = <double>[];

    for (final cell in sorted) {
      if (rows.isEmpty) {
        rows.add([cell]);
        rowMeans.add(cell.centerY);
        continue;
      }

      final lastIdx = rows.length - 1;
      if ((cell.centerY - rowMeans[lastIdx]).abs() <= rowTolerance) {
        final row = rows[lastIdx];
        row.add(cell);
        rowMeans[lastIdx] =
            row.fold<double>(0, (sum, item) => sum + item.centerY) / row.length;
      } else {
        rows.add([cell]);
        rowMeans.add(cell.centerY);
      }
    }

    for (final row in rows) {
      row.sort((a, b) => a.left.compareTo(b.left));
    }

    return rows;
  }

  static List<_ColumnTrack> _discoverColumnTracks(
    List<List<_PositionedCell>> rows, {
    required double medianHeight,
  }) {
    final multiCellRows = rows.where((r) => r.length >= 2).toList();
    if (multiCellRows.isEmpty) {
      return [
        _ColumnTrack(left: 0, right: 1),
      ];
    }

    // Seed tracks from the widest row first so column headers or full rows
    // establish canonical boundaries before sparser rows attach.
    final orderedRows = List<List<_PositionedCell>>.from(multiCellRows)
      ..sort((a, b) => b.length.compareTo(a.length));

    final tracks = <_ColumnTrack>[];
    final overlapPadding = math.max(4.0, 0.2 * medianHeight);

    for (final row in orderedRows) {
      for (final cell in row) {
        final matchIndex = _findOverlappingTrackIndex(
          cell,
          tracks,
          padding: overlapPadding,
        );
        if (matchIndex != null) {
          tracks[matchIndex].expandTo(cell.left, cell.right);
        } else {
          tracks.add(_ColumnTrack(left: cell.left, right: cell.right));
          tracks.sort((a, b) => a.centerX.compareTo(b.centerX));
        }
      }
    }

    return tracks;
  }

  static int? _findOverlappingTrackIndex(
    _PositionedCell cell,
    List<_ColumnTrack> tracks, {
    required double padding,
  }) {
    int? bestIndex;
    var bestOverlap = 0.0;

    for (var i = 0; i < tracks.length; i++) {
      final track = tracks[i];
      final overlapLeft = math.max(cell.left - padding, track.left - padding);
      final overlapRight = math.min(
        cell.right + padding,
        track.right + padding,
      );
      final overlap = overlapRight - overlapLeft;
      if (overlap > bestOverlap) {
        bestOverlap = overlap;
        bestIndex = i;
      }
    }

    return bestIndex;
  }

  static int _assignColumnIndex(
    _PositionedCell cell,
    List<_ColumnTrack> tracks,
  ) {
    final overlapIdx = _findOverlappingTrackIndex(cell, tracks, padding: 2.0);
    if (overlapIdx != null) {
      return overlapIdx;
    }

    var closestIndex = 0;
    var closestDist = double.infinity;
    for (var i = 0; i < tracks.length; i++) {
      final dist = (cell.centerX - tracks[i].centerX).abs();
      if (dist < closestDist) {
        closestDist = dist;
        closestIndex = i;
      }
    }
    return closestIndex;
  }

  static SpatialTableResult? _tryKeyValueOrWhitespaceFallback(
    List<List<_PositionedCell>> rowClusters,
  ) {
    final lineTexts = rowClusters
        .map((row) => row.map((c) => c.text).join(" ").trim())
        .where((line) => line.isNotEmpty)
        .toList();

    final kvPairs = <List<String>>[];
    for (final line in lineTexts) {
      final match = _keyValueRegex.firstMatch(line);
      if (match != null) {
        kvPairs.add([match.group(1)!.trim(), match.group(2)!.trim()]);
      }
    }

    if (kvPairs.length >= 2) {
      return _buildTableResult([
        const ["Field", "Value"],
        ...kvPairs,
      ]);
    }

    return null;
  }

  static SpatialTableResult _reconstructFromPlainText(String rawText) {
    final lines = rawText
        .split(RegExp(r"\r?\n"))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    if (lines.isEmpty) {
      return const SpatialTableResult(
        markdown: "| Column 1 |\n| --- |",
        headers: ["Column 1"],
        rows: [],
        columnAlignments: ["left"],
      );
    }

    final splitRows = <List<String>>[];
    var maxCols = 1;
    for (final line in lines) {
      final parts = line
          .split(RegExp(r"\t|\s*\|\s*|\s{2,}"))
          .map((part) => part.trim())
          .where((part) => part.isNotEmpty)
          .toList();
      if (parts.isNotEmpty) {
        splitRows.add(parts);
        maxCols = math.max(maxCols, parts.length);
      }
    }

    if (maxCols == 1) {
      final kvPairs = <List<String>>[];
      for (final line in lines) {
        final match = _keyValueRegex.firstMatch(line);
        if (match != null) {
          kvPairs.add([match.group(1)!.trim(), match.group(2)!.trim()]);
        }
      }
      if (kvPairs.length >= 2) {
        return _buildTableResult([
          const ["Field", "Value"],
          ...kvPairs,
        ]);
      }
    }

    final padded = splitRows.map((row) {
      if (row.length == maxCols) return row;
      return [...row, ...List<String>.filled(maxCols - row.length, "")];
    }).toList();

    return _buildTableResult(padded);
  }

  static SpatialTableResult _buildTableResult(List<List<String>> matrix) {
    final colCount = matrix.first.length;
    final rawHeaders = matrix.first;
    final headers = <String>[];
    for (var c = 0; c < colCount; c++) {
      final header = c < rawHeaders.length ? rawHeaders[c].trim() : "";
      headers.add(header.isEmpty ? "Column ${c + 1}" : header);
    }

    final dataRows = matrix.length > 1
        ? matrix
              .skip(1)
              .map(
                (row) => List<String>.generate(
                  colCount,
                  (c) => c < row.length ? row[c].trim() : "",
                ),
              )
              .toList()
        : <List<String>>[];

    final alignments = <String>[];
    for (var c = 0; c < colCount; c++) {
      var nonEmptyCount = 0;
      var numericCount = 0;
      for (final row in dataRows) {
        final cell = row[c].trim();
        if (cell.isEmpty) continue;
        nonEmptyCount++;
        if (_numericCellRegex.hasMatch(cell)) {
          numericCount++;
        }
      }
      final isNumericCol =
          nonEmptyCount > 0 && (numericCount / nonEmptyCount) >= 0.6;
      alignments.add(isNumericCol ? "right" : "left");
    }

    final buffer = StringBuffer();
    buffer.writeln("| ${headers.map(_escapeCell).join(" | ")} |");
    final sepCells = alignments
        .map((align) => align == "right" ? "---:" : "---")
        .join(" | ");
    buffer.write("| $sepCells |");

    for (final row in dataRows) {
      buffer.writeln();
      buffer.write("| ${row.map(_escapeCell).join(" | ")} |");
    }

    return SpatialTableResult(
      markdown: buffer.toString(),
      headers: headers,
      rows: dataRows,
      columnAlignments: alignments,
    );
  }

  static String _escapeCell(String value) {
    return value
        .replaceAll("\r\n", " ")
        .replaceAll("\n", " ")
        .replaceAll("|", "\\|")
        .trim();
  }
}
