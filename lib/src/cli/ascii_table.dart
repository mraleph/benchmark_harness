// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:math' as math;

/// A row in the [AsciiTable].
abstract class Row {
  String render(List<int> widths, List<AlignmentDirection> alignments);

  /// Compute the total width of the row given [widths] of individual
  /// columns.
  ///
  /// Note: there is a border on the left and right of each column
  /// plus whitespace around it.
  static int totalWidth(List<int> widths) =>
      widths.fold<int>(0, (sum, width) => sum + width + 3) + 1;
}

enum Separator {
  /// Line separator looks like this: `+-------+------+`
  line,

  /// Wave separator looks like this: `~~~~~~~~~~~~~~~~`.
  wave,
}

/// A separator row in the [AsciiTable].
class SeparatorRow extends Row {
  final Separator filler;
  SeparatorRow(this.filler);

  @override
  String render(List<int> widths, List<AlignmentDirection> alignments) {
    final sb = StringBuffer();
    switch (filler) {
      case Separator.line:
        sb.write('+');
        for (var i = 0; i < widths.length; i++) {
          sb.write('-' * (widths[i] + 2));
          sb.write('+');
        }
        break;

      case Separator.wave:
        sb.write('~' * Row.totalWidth(widths));
        break;
    }
    return sb.toString();
  }
}

/// A separator row in the [AsciiTable].
class TextSeparatorRow extends Row {
  final Text text;
  TextSeparatorRow(String text) : text = Text(text);

  @override
  String render(List<int> widths, List<AlignmentDirection> alignments) {
    return text.render(Row.totalWidth(widths), AlignmentDirection.center);
  }
}

class NormalRow extends Row {
  final List<Text> columns;
  NormalRow(this.columns);

  @override
  String render(List<int> widths, List<AlignmentDirection> alignments) {
    final sb = StringBuffer();
    sb.write('|');
    for (var i = 0; i < widths.length; i++) {
      sb.write(' ');
      sb.write(columns[i].render(widths[i], alignments[i]));
      sb.write(' |');
    }
    return sb.toString();
  }
}

enum AlignmentDirection { left, right, center }

/// A chunk of text aligned in the given direction within a cell.
class Text {
  final String value;
  final AlignmentDirection? direction;

  Text._({required this.value, required this.direction});
  Text.left(String value)
      : this._(value: value, direction: AlignmentDirection.left);
  Text.right(String value)
      : this._(value: value, direction: AlignmentDirection.right);
  Text.center(String value)
      : this._(value: value, direction: AlignmentDirection.center);
  Text(this.value) : direction = null;

  String render(int width, AlignmentDirection columnDirection) {
    if (value.length > width) {
      // Narrowed column.
      return '${value.substring(0, width - 2)}..';
    }

    return switch (direction ?? columnDirection) {
      AlignmentDirection.left => value.padRight(width),
      AlignmentDirection.right => value.padLeft(width),
      AlignmentDirection.center => value.padToCenter(width),
    };
  }

  int get length => value.length;
}

extension on String {
  String padToCenter(int width, [String padding = ' ']) {
    final diff = width - length;
    return padding * (diff ~/ 2) + this + (padding * (diff - diff ~/ 2));
  }
}

class AsciiTable {
  static const int unlimitedWidth = 0;

  final int maxWidth;

  final List<Row> rows = <Row>[];

  AsciiTable({List<Text>? header, this.maxWidth = unlimitedWidth}) {
    if (header != null) {
      addSeparator();
      addRow(header);
      addSeparator();
    }
  }

  void addRow(List<Text> columns) => rows.add(NormalRow(columns));

  void addSeparator([Separator filler = Separator.line]) =>
      rows.add(SeparatorRow(filler));

  void addTextSeparator(String text) => rows.add(TextSeparatorRow(text));

  void render() {
    // We assume that the first row gives us alignment directions that
    // subsequent rows would follow.
    final alignments = rows
        .whereType<NormalRow>()
        .first
        .columns
        .map((v) => v.direction ?? AlignmentDirection.left)
        .toList();
    final widths =
        List<int>.filled(rows.whereType<NormalRow>().first.columns.length, 0);

    // Compute max width for each column in the table.
    for (var row in rows.whereType<NormalRow>()) {
      assert(row.columns.length == widths.length);
      for (var i = 0; i < widths.length; i++) {
        widths[i] = math.max(row.columns[i].length, widths[i]);
      }
    }

    if (maxWidth > 0) {
      for (var i = 0; i < widths.length; i++) {
        widths[i] = math.min(widths[i], maxWidth);
      }
    }

    for (var row in rows) {
      print(row.render(widths, alignments));
    }
  }
}
