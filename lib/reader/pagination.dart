import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'epub_document.dart';

TextStyle readerTextStyle(EpubBlock block, double fontSize) => TextStyle(
  inherit: false,
  fontFamily: 'Lora',
  fontFamilyFallback: const ['Georgia', 'serif'],
  fontSize: block.headingLevel > 0
      ? fontSize + (7 - block.headingLevel) * 2
      : fontSize,
  fontWeight: block.headingLevel > 0 ? FontWeight.w600 : FontWeight.w400,
  height: block.headingLevel > 0 ? 1.35 : 1.6,
);

class PageFragment {
  final EpubBlock block;
  final String text;
  final double height;
  final double gap;
  final bool scaleDown;
  final bool continues;

  String get displayText => _displayText(text, continues);

  const PageFragment({
    required this.block,
    required this.text,
    required this.height,
    this.gap = 0,
    this.scaleDown = false,
    this.continues = false,
  });
}

// A line break at a page boundary must not create an extra empty display line.
String _displayText(String text, bool continues) =>
    continues && text.endsWith('\n')
    ? text.substring(0, text.length - (text.endsWith('\r\n') ? 2 : 1))
    : text;

class ReaderPage {
  final int section;
  final int start;
  final int end;
  final List<PageFragment> fragments;

  ReaderPage({
    required this.section,
    required this.start,
    required this.end,
    required List<PageFragment> fragments,
  }) : fragments = List.unmodifiable(fragments);
}

class ReaderPagination {
  final List<ReaderPage> _pages;
  final List<ReaderPage> pages;
  final List<int> sectionLengths;
  final List<Iterator<ReaderPage>?> _sections;
  final List<int> _pageCounts;

  ReaderPagination._(this._pages, this.sectionLengths, this._sections)
    : pages = UnmodifiableListView(_pages),
      _pageCounts = List.filled(sectionLengths.length, 0);

  bool get isComplete => _sections.every((section) => section == null);

  bool isSectionComplete(int section) => _sections[section] == null;

  bool containsPosition(int section, int offset) {
    final index = locate(section, offset);
    return index >= 0 &&
        (pages[index].end > offset || isSectionComplete(section));
  }

  /// Shapes at most [maxPages] pages, without laying out other sections.
  /// Callers control frame yielding and cancellation between these batches.
  void advanceSection(int section, {int maxPages = 1}) {
    final iterator = _sections[section];
    if (iterator == null) return;
    var insertion = _pageCounts.take(section + 1).fold(0, (a, b) => a + b);
    for (var count = 0; count < maxPages; count++) {
      if (!iterator.moveNext()) {
        _sections[section] = null;
        break;
      }
      final page = iterator.current;
      _pages.insert(insertion++, page);
      _pageCounts[section]++;
      if (page.end == sectionLengths[section]) {
        _sections[section] = null;
        break;
      }
    }
  }

  int locate(int section, int offset) {
    var low = 0;
    var high = pages.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      final page = pages[middle];
      if (page.section < section ||
          (page.section == section && page.start <= offset)) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    final found = low - 1;
    return found >= 0 && pages[found].section == section ? found : -1;
  }

  int? remainingInChapter(int index) {
    if (!isSectionComplete(pages[index].section)) return null;
    var remaining = 0;
    for (var next = index + 1; next < pages.length; next++) {
      if (pages[next].section != pages[index].section) break;
      remaining++;
    }
    return remaining;
  }

  double progressAt(int index) {
    final page = pages[index];
    final before = sectionLengths.take(page.section).fold(0, (a, b) => a + b);
    final total = sectionLengths.fold(0, (a, b) => a + b);
    return total == 0 ? 0 : ((before + page.end) / total).clamp(0.0, 1.0);
  }

  static int offsetForLegacyScroll(
    EpubSection section, {
    required double scroll,
    required double width,
    required TextScaler textScaler,
    required TextDirection direction,
  }) {
    var top = 24.0;
    var offset = 0;
    if (scroll <= top) return 0;
    for (final block in section.blocks) {
      if (block.image != null) {
        if (top + width * 3 / 4 > scroll) return offset;
        top += width * 3 / 4 + 18;
        offset++;
        continue;
      }
      final painter = TextPainter(
        text: TextSpan(
          text: block.text,
          style: readerTextStyle(block, 22).copyWith(height: 1.65),
        ),
        textDirection: direction,
        textScaler: textScaler,
      )..layout(maxWidth: math.max(1, width));
      try {
        if (top + painter.height > scroll) {
          final position = painter.getPositionForOffset(
            Offset(0, math.max(0, scroll - top)),
          );
          return offset + painter.getLineBoundary(position).start;
        }
        top += painter.height + (block.headingLevel > 0 ? 24 : 18);
        offset += block.text.length;
      } finally {
        painter.dispose();
      }
    }
    return offset;
  }

  static ReaderPagination layout(
    EpubDocument document, {
    required Size size,
    required double fontSize,
    required TextScaler textScaler,
    required TextDirection direction,
    bool boldText = false,
    double? lineHeight,
    double? letterSpacing,
    double? wordSpacing,
    Locale? locale,
  }) {
    final pagination = ReaderPagination.incremental(
      document,
      size: size,
      fontSize: fontSize,
      textScaler: textScaler,
      direction: direction,
      boldText: boldText,
      lineHeight: lineHeight,
      letterSpacing: letterSpacing,
      wordSpacing: wordSpacing,
      locale: locale,
    );
    for (var section = 0; section < document.sections.length; section++) {
      while (!pagination.isSectionComplete(section)) {
        pagination.advanceSection(section);
      }
    }
    return pagination;
  }

  static ReaderPagination incremental(
    EpubDocument document, {
    required Size size,
    required double fontSize,
    required TextScaler textScaler,
    required TextDirection direction,
    bool boldText = false,
    double? lineHeight,
    double? letterSpacing,
    double? wordSpacing,
    Locale? locale,
  }) => ReaderPagination._(
    [],
    List.unmodifiable([
      for (final section in document.sections)
        section.blocks.fold<int>(
          0,
          (length, block) =>
              length + (block.image == null ? block.text.length : 1),
        ),
    ]),
    [
      for (var section = 0; section < document.sections.length; section++)
        _layoutSection(
          document.sections[section],
          section,
          size: size,
          fontSize: fontSize,
          textScaler: textScaler,
          direction: direction,
          boldText: boldText,
          lineHeight: lineHeight,
          letterSpacing: letterSpacing,
          wordSpacing: wordSpacing,
          locale: locale,
        ).iterator,
    ],
  );

  static Iterable<ReaderPage> _layoutSection(
    EpubSection chapter,
    int section, {
    required Size size,
    required double fontSize,
    required TextScaler textScaler,
    required TextDirection direction,
    required bool boldText,
    double? lineHeight,
    double? letterSpacing,
    double? wordSpacing,
    Locale? locale,
  }) sync* {
    final width = math.max(1.0, size.width);
    final height = math.max(1.0, size.height);
    var blockIndex = 0;
    var offset = 0;
    var cursor = 0;
    while (blockIndex < chapter.blocks.length) {
      var fragments = <PageFragment>[];
      var used = 0.0;
      final start = cursor;
      while (blockIndex < chapter.blocks.length) {
        final block = chapter.blocks[blockIndex];
        if (block.image != null) {
          final imageHeight = math.min(width * 3 / 4, height);
          if (used + imageHeight > height && fragments.isNotEmpty) break;
          final gap = math.min(18.0, height - used - imageHeight);
          fragments.add(
            PageFragment(
              block: block,
              text: block.text,
              height: imageHeight,
              gap: gap,
            ),
          );
          cursor++;
          used += imageHeight + gap;
          blockIndex++;
          continue;
        }
        if (block.text.isEmpty) {
          blockIndex++;
          continue;
        }
        final available = height - used;
        if (available <= 0 && fragments.isNotEmpty) break;
        final style = readerTextStyle(block, fontSize).copyWith(
          fontWeight: boldText ? FontWeight.bold : null,
          height: lineHeight,
          letterSpacing: letterSpacing,
          wordSpacing: wordSpacing,
        );
        final painter = TextPainter(
          textDirection: direction,
          textScaler: textScaler,
          locale: locale,
        );
        var end = offset;
        var naturalHeight = 0.0;
        try {
          // Bound shaping to a page-sized prefix even for enormous paragraphs.
          // Ignore the prefix's last (possibly truncated) line. Grow only when
          // the complete lines do not yet cover the available page height.
          var limit = math.min(block.text.length, offset + 512);
          List<LineMetrics> lines;
          while (true) {
            painter.text = TextSpan(
              text: block.text.substring(offset, limit),
              style: style,
            );
            painter.layout(maxWidth: width);
            lines = painter.computeLineMetrics();
            final completeHeight = lines
                .take(math.max(0, lines.length - 1))
                .fold(0.0, (sum, line) => sum + line.height);
            var safeEnd = 0;
            if (lines.length > 1) {
              final last = lines.last;
              final position = painter.getPositionForOffset(
                Offset(last.left + last.width / 2, last.baseline),
              );
              safeEnd = painter.getLineBoundary(position).start;
            }
            if (limit == block.text.length ||
                (completeHeight > available && safeEnd > 0)) {
              break;
            }
            limit = math.min(block.text.length, offset + (limit - offset) * 2);
          }
          final starts = [0];
          for (var index = 1; index < lines.length; index++) {
            final line = lines[index];
            final position = painter.getPositionForOffset(
              Offset(line.left + line.width / 2, line.baseline),
            );
            starts.add(painter.getLineBoundary(position).start);
          }
          starts.add(limit - offset);
          var nextLine = 0;
          var occupied = 0.0;
          final usable = limit == block.text.length
              ? lines.length
              : lines.length - 1;
          while (nextLine < usable &&
              occupied + lines[nextLine].height <= available + 0.001) {
            occupied += lines[nextLine++].height;
          }
          nextLine = math.max(1, nextLine);
          while (nextLine < usable && starts[nextLine] == 0) {
            nextLine++;
          }
          end = offset + starts[nextLine];
          while (true) {
            painter.text = TextSpan(
              text: _displayText(
                block.text.substring(offset, end),
                end < block.text.length,
              ),
              style: style,
            );
            painter.layout(maxWidth: width);
            naturalHeight = painter.height;
            if (naturalHeight <= available + 0.001 || nextLine <= 1) break;
            final previous = offset + starts[nextLine - 1];
            if (previous <= offset) break;
            nextLine--;
            end = previous;
          }
        } finally {
          painter.dispose();
        }
        if (naturalHeight > available + 0.001 && fragments.isNotEmpty) break;
        final fragmentHeight = math.min(naturalHeight, available);
        final complete = end == block.text.length;
        final gap = complete
            ? math.min(
                block.headingLevel > 0 ? 24.0 : 18.0,
                math.max(0.0, available - fragmentHeight),
              )
            : 0.0;
        fragments.add(
          PageFragment(
            block: block,
            text: block.text.substring(offset, end),
            height: fragmentHeight,
            gap: gap,
            scaleDown: naturalHeight > fragmentHeight + 0.001,
            continues: !complete,
          ),
        );
        used += fragmentHeight + gap;
        cursor += end - offset;
        offset = end;
        if (!complete) break;
        blockIndex++;
        offset = 0;
      }
      // No TextPainter survives a yield, including when a reader is discarded.
      if (fragments.isNotEmpty) {
        yield ReaderPage(
          section: section,
          start: start,
          end: cursor,
          fragments: fragments,
        );
      }
    }
  }
}
