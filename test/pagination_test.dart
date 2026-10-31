import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leitura_anywhere/reader/epub_document.dart';
import 'package:leitura_anywhere/reader/pagination.dart';

EpubDocument _document(List<List<EpubBlock>> chapters) => EpubDocument(
  title: 'Pagination fixture',
  author: 'Test author',
  sections: [
    for (var i = 0; i < chapters.length; i++)
      EpubSection(title: 'Chapter $i', blocks: chapters[i]),
  ],
);

ReaderPagination _layout(
  EpubDocument document, {
  Size size = const Size(260, 180),
  double fontSize = 22,
  TextScaler textScaler = TextScaler.noScaling,
  TextDirection direction = TextDirection.ltr,
}) => ReaderPagination.layout(
  document,
  size: size,
  fontSize: fontSize,
  textScaler: textScaler,
  direction: direction,
);

List<int> _lengths(EpubDocument document) => [
  for (final section in document.sections)
    section.blocks.fold<int>(
      0,
      (length, block) => length + (block.image == null ? block.text.length : 1),
    ),
];

// Check source order and exact UTF-16 coverage, not just concatenated lengths.
void _expectIntegrity(
  ReaderPagination pagination,
  EpubDocument document,
  Size size,
) {
  final lengths = _lengths(document);
  expect(pagination.sectionLengths, orderedEquals(lengths));
  final cursors = List<int>.filled(lengths.length, 0);
  var previousSection = -1;
  for (var i = 0; i < pagination.pages.length; i++) {
    final page = pagination.pages[i];
    final reason = 'page $i, section ${page.section}';
    expect(page.section, inInclusiveRange(0, lengths.length - 1));
    expect(page.section, greaterThanOrEqualTo(previousSection), reason: reason);
    previousSection = page.section;
    expect(page.fragments, isNotEmpty, reason: reason);
    expect(page.start, cursors[page.section], reason: reason);
    expect(page.end, greaterThan(page.start), reason: reason);
    expect(page.end, lessThanOrEqualTo(lengths[page.section]), reason: reason);
    var units = 0;
    var height = 0.0;
    for (final fragment in page.fragments) {
      expect(fragment.height.isFinite, isTrue, reason: reason);
      expect(fragment.height, greaterThan(0), reason: reason);
      expect(fragment.gap.isFinite, isTrue, reason: reason);
      expect(fragment.gap, greaterThanOrEqualTo(0), reason: reason);
      height += fragment.height + fragment.gap;
      units += fragment.block.image == null ? fragment.text.length : 1;
    }
    expect(height, lessThanOrEqualTo(size.height + 0.000001), reason: reason);
    expect(page.end - page.start, units, reason: reason);
    cursors[page.section] = page.end;
  }
  expect(cursors, orderedEquals(lengths));

  for (var section = 0; section < document.sections.length; section++) {
    final fragments = pagination.pages
        .where((page) => page.section == section)
        .expand((page) => page.fragments)
        .toList();
    var index = 0;
    for (final block in document.sections[section].blocks) {
      if (block.image != null) {
        expect(index, lessThan(fragments.length));
        expect(fragments[index].block, same(block));
        expect(fragments[index].text, block.text);
        index++;
        continue;
      }
      final boundaries = <int>{0};
      var boundary = 0;
      for (final character in block.text.characters) {
        boundary += character.length;
        boundaries.add(boundary);
      }
      final restored = StringBuffer();
      while (restored.length < block.text.length) {
        expect(index, lessThan(fragments.length));
        final fragment = fragments[index++];
        expect(fragment.block, same(block));
        expect(fragment.text, isNotEmpty);
        restored.write(fragment.text);
        expect(
          boundaries,
          contains(restored.length),
          reason: 'section $section splits a grapheme at ${restored.length}',
        );
      }
      expect(restored.toString(), block.text, reason: 'section $section');
    }
    expect(
      index,
      fragments.length,
      reason: 'section $section has extra content',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Exercise the reader's real font metrics rather than the test Ahem font.
    final loader = FontLoader('Lora')
      ..addFont(rootBundle.load('assets/fonts/Lora.ttf'));
    await loader.load();
  });

  group('incremental pagination', () {
    ReaderPagination incremental(EpubDocument document) =>
        ReaderPagination.incremental(
          document,
          size: const Size(260, 180),
          fontSize: 22,
          textScaler: TextScaler.noScaling,
          direction: TextDirection.ltr,
        );

    test('lays out only the requested section and explicit page budget', () {
      final document = _document([
        [EpubBlock(text: List.filled(10000, 'Unvisited chapter. ').join())],
        [EpubBlock(text: List.filled(120, 'Saved chapter. ').join())],
        [const EpubBlock(text: 'Later chapter.')],
      ]);
      final result = incremental(document);
      expect(result.pages, isEmpty);
      expect(result.locate(1, 0), -1);
      expect(result.containsPosition(1, 0), isFalse);
      result.advanceSection(1);
      expect(result.pages, hasLength(1));
      expect(result.pages.single.section, 1);
      expect(result.isComplete, isFalse);
      expect(result.isSectionComplete(0), isFalse);
      expect(result.isSectionComplete(1), isFalse);
      expect(result.remainingInChapter(0), isNull);
      expect(result.containsPosition(1, 0), isTrue);
      expect(result.containsPosition(1, result.pages.single.end), isFalse);
      result.advanceSection(1, maxPages: 2);
      expect(result.pages, hasLength(3));
      expect(result.pages.every((page) => page.section == 1), isTrue);
      expect(() => result.pages.clear(), throwsUnsupportedError);
    });

    test(
      'restores a deep anchor before laying out later pages or chapters',
      () {
        final document = _document([
          [EpubBlock(text: List.filled(20, 'Previous. ').join())],
          [EpubBlock(text: List.filled(200, 'Anchor content. ').join())],
          [const EpubBlock(text: 'Last.')],
        ]);
        final result = incremental(document);
        const offset = 700;
        while (!result.containsPosition(1, offset)) {
          result.advanceSection(1);
        }
        expect(result.locate(1, offset), result.pages.length - 1);
        expect(result.pages.last.start, lessThanOrEqualTo(offset));
        expect(result.pages.last.end, greaterThan(offset));
        expect(result.pages.every((page) => page.section == 1), isTrue);
        expect(result.isSectionComplete(1), isFalse);
        final restored = result.pages.last;
        final progress = result.progressAt(result.pages.length - 1);
        for (final section in [2, 0, 1]) {
          while (!result.isSectionComplete(section)) {
            result.advanceSection(section, maxPages: 2);
          }
        }
        expect(result.isComplete, isTrue);
        final index = result.locate(1, offset);
        expect(result.pages[index], same(restored));
        expect(result.progressAt(index), progress);
        _expectIntegrity(result, document, const Size(260, 180));
        final eager = _layout(document);
        expect(
          result.pages.map((page) => (page.section, page.start, page.end)),
          orderedEquals(
            eager.pages.map((page) => (page.section, page.start, page.end)),
          ),
        );
      },
    );

    test(
      'bounds a huge paragraph and preserves Unicode at shaping windows',
      () {
        const sample = 'a\u0301 \u{1f469}\u{1f3fd}\u200d\u{1f4bb} word\n';
        final text = List.filled(10000, sample).join();
        final document = _document([
          [EpubBlock(text: text)],
        ]);
        final result = incremental(document);
        result.advanceSection(0, maxPages: 3);
        expect(result.pages, hasLength(3));
        expect(result.pages.last.end, lessThan(text.length ~/ 100));
        expect(result.isComplete, isFalse);
        final boundaries = <int>{0};
        var cursor = 0;
        for (final character in text.characters) {
          cursor += character.length;
          boundaries.add(cursor);
          if (cursor > result.pages.last.end) break;
        }
        for (final page in result.pages) {
          expect(boundaries, contains(page.end));
        }
        expect(
          result.pages
              .expand((page) => page.fragments)
              .map((f) => f.text)
              .join(),
          text.substring(0, result.pages.last.end),
        );
      },
    );

    test('empty sections complete without phantom pages or extra work', () {
      final result = incremental(
        _document([
          [],
          [const EpubBlock(text: 'Only page')],
        ]),
      );
      result.advanceSection(0);
      expect(result.pages, isEmpty);
      expect(result.isSectionComplete(0), isTrue);
      result.advanceSection(1);
      expect(result.isComplete, isTrue);
      expect(result.remainingInChapter(0), 0);
      result.advanceSection(1);
      expect(result.pages, hasLength(1));
    });
  });

  group('exact text reconstruction', () {
    final samples = [
      (
        name: 'Unicode and supplementary characters',
        text:
            'A\u00e7\u00e3o \u4e2d\u6587 \u03b1\u03b2 '
            '\u{1f680} \u{1d11e} fim. ',
        direction: TextDirection.ltr,
      ),
      (
        name: 'ZWJ emoji, skin tones, flags and combining marks',
        text:
            '\u{1f469}\u{1f3fd}\u200d\u{1f4bb} '
            '\u{1f468}\u200d\u{1f469}\u200d\u{1f467}\u200d\u{1f466} '
            '\u{1f1e7}\u{1f1f7} a\u0301 e\u0308 o\u0323\u0302 ',
        direction: TextDirection.ltr,
      ),
      (
        name: 'RTL Arabic, Hebrew and mixed Latin numbers',
        text:
            '\u0645\u0631\u062d\u0628\u0627 '
            '\u0628\u0627\u0644\u0639\u0627\u0644\u0645 '
            '\u05e9\u05dc\u05d5\u05dd 123 ABC. ',
        direction: TextDirection.rtl,
      ),
      (
        name: 'leading, consecutive and trailing newlines and whitespace',
        text: '\n  first\n\nsecond\r\n\tthird  \n',
        direction: TextDirection.ltr,
      ),
      (
        name: 'long paragraph without word boundaries',
        text: List.filled(80, 'abcdefghij').join(),
        direction: TextDirection.ltr,
      ),
    ];
    for (final sample in samples) {
      test('preserves ${sample.name} across pages', () {
        const size = Size(113, 97);
        final document = _document([
          [
            const EpubBlock(text: 'Heading', headingLevel: 1),
            EpubBlock(text: List.filled(12, sample.text).join()),
            const EpubBlock(text: 'Last paragraph.  '),
          ],
        ]);
        final pagination = _layout(
          document,
          size: size,
          direction: sample.direction,
        );
        expect(pagination.pages.length, greaterThan(2));
        _expectIntegrity(pagination, document, size);
      });
    }

    test('preserves all heading levels and long multi-page titles', () {
      const size = Size(177, 131);
      final document = _document([
        [
          for (var level = 1; level <= 6; level++)
            EpubBlock(
              text: List.filled(10, 'Title $level with several words. ').join(),
              headingLevel: level,
            ),
          EpubBlock(
            text: List.filled(40, 'The long paragraph continues. ').join(),
          ),
        ],
      ]);
      final pagination = _layout(document, size: size);
      _expectIntegrity(pagination, document, size);
      for (final block in document.sections.single.blocks) {
        expect(
          pagination.pages
              .where(
                (page) => page.fragments.any((f) => identical(f.block, block)),
              )
              .length,
          greaterThan(1),
        );
      }
    });
  });

  group('chapters and navigation', () {
    late EpubDocument document;
    late ReaderPagination pagination;
    const size = Size(233, 173);
    setUp(() {
      document = _document([
        [
          const EpubBlock(text: 'Chapter one', headingLevel: 1),
          EpubBlock(text: List.filled(35, 'First chapter content. ').join()),
        ],
        [const EpubBlock(text: 'Short chapter.')],
        [
          EpubBlock(
            text: List.filled(29, 'Another chapter, another page. ').join(),
          ),
        ],
      ]);
      pagination = _layout(document, size: size);
    });

    test('has contiguous section-local anchors and never mixes chapters', () {
      _expectIntegrity(pagination, document, size);
      for (var section = 0; section < document.sections.length; section++) {
        final pages = pagination.pages.where((page) => page.section == section);
        expect(pages.first.start, 0);
        expect(pages.last.end, _lengths(document)[section]);
      }
    });

    test('starts a new page at each chapter even when both chapters fit', () {
      final shortDocument = _document([
        [const EpubBlock(text: 'One')],
        [const EpubBlock(text: 'Two')],
        [const EpubBlock(text: 'Three')],
      ]);
      const largeSize = Size(1000, 1000);
      final result = _layout(shortDocument, size: largeSize);
      expect(
        result.pages.map((page) => page.section),
        orderedEquals([0, 1, 2]),
      );
      _expectIntegrity(result, shortDocument, largeSize);
    });

    test('locate resolves starts, interiors, page ends and chapter ends', () {
      for (var i = 0; i < pagination.pages.length; i++) {
        final page = pagination.pages[i];
        for (final offset in {
          page.start,
          (page.start + page.end) ~/ 2,
          page.end - 1,
        }) {
          expect(pagination.locate(page.section, offset), i);
        }
        final lastInChapter =
            i == pagination.pages.length - 1 ||
            pagination.pages[i + 1].section != page.section;
        expect(
          pagination.locate(page.section, page.end),
          lastInChapter ? i : i + 1,
        );
      }
    });

    test('remainingInChapter excludes the current page and later chapters', () {
      expect(
        pagination.pages.where((page) => page.section == 0).length,
        greaterThan(1),
      );
      for (var i = 0; i < pagination.pages.length; i++) {
        final section = pagination.pages[i].section;
        final expected = pagination.pages
            .skip(i + 1)
            .where((page) => page.section == section)
            .length;
        expect(pagination.remainingInChapter(i), expected, reason: 'page $i');
      }
      final shortChapter = pagination.pages.indexWhere(
        (page) => page.section == 1,
      );
      expect(pagination.remainingInChapter(shortChapter), 0);
      expect(pagination.remainingInChapter(pagination.pages.length - 1), 0);
    });

    test(
      'progress is weighted by source offsets, monotone and ends at one',
      () {
        final lengths = _lengths(document);
        final total = lengths.fold<int>(0, (sum, length) => sum + length);
        var previous = 0.0;
        for (var i = 0; i < pagination.pages.length; i++) {
          final page = pagination.pages[i];
          final before = lengths
              .take(page.section)
              .fold<int>(0, (a, b) => a + b);
          final progress = pagination.progressAt(i);
          expect(progress.isFinite, isTrue);
          expect(progress, inInclusiveRange(previous, 1.0));
          expect(progress, closeTo((before + page.end) / total, 0.000000001));
          previous = progress;
        }
        expect(pagination.progressAt(pagination.pages.length - 1), 1.0);
      },
    );
  });

  group('repagination preserves source anchors', () {
    final variants = [
      (
        name: 'narrower viewport',
        size: const Size(137, 119),
        font: 22.0,
        scale: 1.0,
      ),
      (
        name: 'larger viewport',
        size: const Size(480, 530),
        font: 22.0,
        scale: 1.0,
      ),
      (name: 'larger font', size: const Size(260, 180), font: 34.0, scale: 1.0),
      (
        name: 'smaller font',
        size: const Size(260, 180),
        font: 15.0,
        scale: 1.0,
      ),
      (
        name: 'accessibility scaler',
        size: const Size(260, 180),
        font: 22.0,
        scale: 1.8,
      ),
    ];
    for (final variant in variants) {
      test(variant.name, () {
        final document = _document([
          for (var section = 0; section < 3; section++)
            [
              EpubBlock(text: 'Chapter $section', headingLevel: 2),
              EpubBlock(
                text: List.generate(
                  35,
                  (i) => 'Paragraph $i: cafe\u0301 \u{1f469}\u200d\u{1f4bb}.\n',
                ).join(),
              ),
            ],
        ]);
        final original = _layout(document);
        final result = _layout(
          document,
          size: variant.size,
          fontSize: variant.font,
          textScaler: TextScaler.linear(variant.scale),
        );
        expect(result.pages.length, isNot(original.pages.length));
        _expectIntegrity(result, document, variant.size);
        for (final oldPage in original.pages) {
          for (final anchor in {
            oldPage.start,
            (oldPage.start + oldPage.end) ~/ 2,
            oldPage.end - 1,
          }) {
            final index = result.locate(oldPage.section, anchor);
            final page = result.pages[index];
            expect(page.section, oldPage.section);
            expect(page.start, lessThanOrEqualTo(anchor));
            expect(page.end, greaterThan(anchor));
            final source = document.sections[page.section].blocks
                .map((block) => block.text)
                .join();
            final text = page.fragments.map((fragment) => fragment.text).join();
            expect(text, source.substring(page.start, page.end));
          }
        }
      });
    }
  });

  test('local images keep bytes and alt once, with one anchor unit each', () {
    // Pagination must carry local bytes without decoding pixels or fetching URLs.
    final bytes = Uint8List.fromList([137, 80, 78, 71]);
    final image = EpubBlock(text: 'Local illustration \u{1f333}', image: bytes);
    final decorative = EpubBlock(text: '', image: bytes);
    final document = _document([
      [
        const EpubBlock(text: 'Before the illustration.'),
        image,
        decorative,
        EpubBlock(
          text: List.filled(10, 'Unavailable image: alt text only. ').join(),
        ),
      ],
      [EpubBlock(text: 'Image-only chapter', image: bytes)],
    ]);
    const size = Size(180, 150);
    final pagination = _layout(document, size: size);
    _expectIntegrity(pagination, document, size);
    final images = pagination.pages
        .expand((page) => page.fragments)
        .where((fragment) => fragment.block.image != null)
        .toList();
    expect(images, hasLength(3));
    expect(images.map((fragment) => fragment.text), [
      image.text,
      '',
      'Image-only chapter',
    ]);
    for (final fragment in images) {
      expect(fragment.block.image, same(bytes));
      expect(fragment.height, 135);
    }
    final firstImagePage = pagination.pages.indexWhere(
      (page) =>
          page.fragments.any((fragment) => identical(fragment.block, image)),
    );
    expect(
      pagination.locate(0, 'Before the illustration.'.length),
      firstImagePage,
    );
    expect(pagination.sectionLengths.last, 1);
    expect(pagination.progressAt(pagination.pages.length - 1), 1.0);
  });

  for (final height in [1.0, 12.0, 35.0]) {
    test(
      'short viewport ($height px) fits images and scales oversized lines',
      () {
        final size = Size(113, height);
        final document = _document([
          [
            const EpubBlock(text: 'Oversized heading', headingLevel: 1),
            const EpubBlock(
              text: 'a\u0301 \u{1f469}\u200d\u{1f4bb}\n\nlast line\n',
            ),
            EpubBlock(
              text: 'Local image',
              image: Uint8List.fromList([1, 2, 3]),
            ),
            const EpubBlock(text: 'After image.'),
          ],
        ]);
        final scaler = TextScaler.linear(2.2);
        final pagination = _layout(
          document,
          size: size,
          fontSize: 32,
          textScaler: scaler,
        );
        _expectIntegrity(pagination, document, size);
        final fragments = pagination.pages
            .expand((page) => page.fragments)
            .toList();
        expect(fragments.any((fragment) => fragment.scaleDown), isTrue);
        expect(
          fragments.singleWhere((f) => f.block.image != null).height,
          height,
        );
        for (final fragment in fragments.where((f) => f.block.image == null)) {
          final painter = TextPainter(
            text: TextSpan(
              text: fragment.displayText,
              style: readerTextStyle(fragment.block, 32),
            ),
            textScaler: scaler,
            textDirection: TextDirection.ltr,
          );
          try {
            painter.layout(maxWidth: size.width);
            expect(
              fragment.scaleDown,
              painter.height > fragment.height + 0.001,
            );
            if (!fragment.scaleDown) {
              expect(
                painter.height,
                lessThanOrEqualTo(fragment.height + 0.001),
              );
            }
          } finally {
            painter.dispose();
          }
        }
      },
    );
  }

  test('page-boundary newlines do not shrink a line that fits', () {
    const block = EpubBlock(text: 'first\nsecond\nthird');
    final painter = TextPainter(
      text: TextSpan(text: 'first', style: readerTextStyle(block, 22)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 300);
    final height = painter.height;
    painter.dispose();
    final result = _layout(
      _document([
        [block],
      ]),
      size: Size(300, height),
    );
    expect(result.pages, hasLength(3));
    expect(result.pages.first.fragments.single.text, 'first\n');
    expect(result.pages.first.fragments.single.displayText, 'first');
    expect(
      result.pages.expand((page) => page.fragments).any((f) => f.scaleDown),
      isFalse,
    );
    _expectIntegrity(
      result,
      _document([
        [block],
      ]),
      Size(300, height),
    );
  });

  test('empty documents and empty blocks produce no phantom pages', () {
    final empty = _layout(_document([]));
    expect(empty.pages, isEmpty);
    expect(empty.sectionLengths, isEmpty);
    final document = _document([
      [],
      [const EpubBlock(text: '')],
      [const EpubBlock(text: ''), const EpubBlock(text: 'Only content.')],
      [],
    ]);
    final pagination = _layout(document);
    _expectIntegrity(pagination, document, const Size(260, 180));
    expect(pagination.pages, hasLength(1));
    expect(pagination.pages.single.section, 2);
    expect(pagination.locate(2, 0), 0);
    expect(pagination.remainingInChapter(0), 0);
    expect(pagination.progressAt(0), 1.0);
  });
}
