import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:leitura_anywhere/data/book.dart';
import 'package:leitura_anywhere/data/library.dart';
import 'package:leitura_anywhere/reader/epub_document.dart';
import 'package:leitura_anywhere/reader/pagination.dart';
import 'package:leitura_anywhere/reader/reader_screen.dart';

import 'support/epub_fixture.dart';

Uint8List _expandedEpub({int paragraphs = 180, int secondParagraphs = 1}) {
  final archive = Archive();
  for (final file in ZipDecoder().decodeBytes(fixtureEpub()).files) {
    if (file.name != 'one.xhtml' && file.name != 'two.xhtml') {
      archive.addFile(file);
    }
  }
  for (final (name, count) in [
    ('one.xhtml', paragraphs),
    ('two.xhtml', secondParagraphs),
  ]) {
    final content = utf8.encode(
      '<html xmlns="http://www.w3.org/1999/xhtml"><body><h1>$name</h1>'
      '${List.generate(count, (i) => '<p>Paragraph $i. Reading continues with words across several lines. Every page preserves its source position.</p>').join()}'
      '</body></html>',
    );
    archive.addFile(ArchiveFile(name, content.length, content));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Box<dynamic> box;
  late Library library;
  late EpubDocument document;
  late EpubDocument fixtureDocument;
  late ValueNotifier<MediaQueryData> accessibility;
  final page = find.byKey(const ValueKey('reader-page'));
  final pageNumber = find.byKey(const ValueKey('reader-page-number'));

  setUpAll(() async {
    final loader = FontLoader('Lora')
      ..addFont(rootBundle.load('assets/fonts/Lora.ttf'));
    await loader.load();
    fixtureDocument = await EpubDocument.parse(fixtureEpub());
  });

  setUp(() async {
    document = fixtureDocument;
    box = await Hive.openBox<dynamic>('reader-screen', bytes: Uint8List(0));
    library = Library(box);
    await library.load();
    await library.add(
      Book(id: 'reader', title: 'Fixture', author: 'Author', source: 'Test'),
      fixtureEpub(),
    );
    accessibility = ValueNotifier(const MediaQueryData());
  });

  tearDown(() async {
    accessibility.dispose();
    library.dispose();
    if (box.isOpen) await box.close();
  });

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(430, 800),
    VoidCallback? onReady,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => ValueListenableBuilder<MediaQueryData>(
          valueListenable: accessibility,
          builder: (context, data, _) => MediaQuery(
            data: data.copyWith(size: MediaQuery.sizeOf(context)),
            child: child!,
          ),
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => ReaderScreen(
                      library: library,
                      bookId: 'reader',
                      onReady: onReady,
                    ),
                  ),
                ),
                child: const Text('Open reader'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openReader(WidgetTester tester, {bool settle = true}) async {
    await tester.tap(find.text('Open reader'));
    await tester.pump();
    // EPUB parsing uses a real isolate, outside the widget test clock.
    for (var attempt = 0; attempt < 80 && page.evaluate().isEmpty; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 25));
    }
    if (settle) await tester.pumpAndSettle();
    expect(page, findsOneWidget);
  }

  Future<void> saveDebounce(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 650));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  ReaderPagination expectPage(
    WidgetTester tester, {
    required int section,
    required int offset,
    double fontSize = 22,
  }) {
    final context = tester.element(page);
    final media = MediaQuery.of(context);
    final overrides = accessibility.value;
    expect(media.boldText, overrides.boldText);
    expect(media.textScaler.scale(22), overrides.textScaler.scale(22));
    expect(
      media.lineHeightScaleFactorOverride,
      overrides.lineHeightScaleFactorOverride,
    );
    expect(media.letterSpacingOverride, overrides.letterSpacingOverride);
    expect(media.wordSpacingOverride, overrides.wordSpacingOverride);
    final pagination = ReaderPagination.layout(
      document,
      size: tester.getSize(page),
      fontSize: fontSize,
      textScaler: media.textScaler,
      direction: Directionality.of(context),
      locale: Localizations.localeOf(context),
      boldText: media.boldText,
      lineHeight: media.lineHeightScaleFactorOverride,
      letterSpacing: media.letterSpacingOverride,
      wordSpacing: media.wordSpacingOverride,
    );
    final index = pagination.locate(section, offset);
    final expected = pagination.pages[index];
    expect(expected.section, section);
    expect(expected.start, lessThanOrEqualTo(offset));
    expect(expected.end, greaterThan(offset));
    expect(
      tester.widget<Text>(pageNumber).data,
      'P\u00e1gina ${index + 1} de ${pagination.pages.length}',
    );
    expect(
      tester
          .widgetList<Text>(
            find.descendant(of: page, matching: find.byType(Text)),
          )
          .map((text) => text.data),
      orderedEquals(expected.fragments.map((fragment) => fragment.displayText)),
    );

    // Text can clip silently inside its fixed-height fragment without a Flex
    // overflow. Check real paragraph metrics as well as framework exceptions.
    final pageRect = tester.getRect(page);
    for (final element
        in find
            .descendant(of: page, matching: find.byType(RichText))
            .evaluate()) {
      final paragraph = element.renderObject! as RenderParagraph;
      final style = paragraph.text.style!;
      if (overrides.boldText) expect(style.fontWeight, FontWeight.bold);
      if (overrides.lineHeightScaleFactorOverride != null) {
        expect(style.height, overrides.lineHeightScaleFactorOverride);
      }
      if (overrides.letterSpacingOverride != null) {
        expect(style.letterSpacing, overrides.letterSpacingOverride);
      }
      if (overrides.wordSpacingOverride != null) {
        expect(style.wordSpacing, overrides.wordSpacingOverride);
      }
      expect(
        paragraph.getMaxIntrinsicHeight(paragraph.size.width),
        lessThanOrEqualTo(paragraph.size.height + 0.01),
        reason: 'Reader text must not be clipped by its fragment',
      );
      final rect = paragraph.localToGlobal(Offset.zero) & paragraph.size;
      expect(rect.top, greaterThanOrEqualTo(pageRect.top - 0.01));
      expect(rect.bottom, lessThanOrEqualTo(pageRect.bottom + 0.01));
      expect(rect.left, greaterThanOrEqualTo(pageRect.left - 0.01));
      expect(rect.right, lessThanOrEqualTo(pageRect.right + 0.01));
    }
    expect(tester.takeException(), isNull);
    return pagination;
  }

  void expectSaved(LocalBook anchor) {
    final saved = library.find('reader')!;
    final state = box.get('@state/reader') as Map;
    expect(saved.section, anchor.section);
    expect(saved.textOffset, anchor.textOffset);
    expect(saved.progress, anchor.progress);
    expect(state['section'], anchor.section);
    expect(state['textOffset'], anchor.textOffset);
    expect(state['progress'], anchor.progress);
    expect(state['scroll'], 0);
  }

  Future<void> installExpandedBook(
    WidgetTester tester, {
    int secondParagraphs = 1,
    int section = 0,
    int offset = 0,
    double? progress,
  }) async {
    final bytes = _expandedEpub(secondParagraphs: secondParagraphs);
    await tester.runAsync(() async {
      document = await EpubDocument.parse(bytes);
      await library.add(library.find('reader')!.book, bytes);
      await library.updatePosition(
        'reader',
        section,
        0,
        textOffset: offset,
        progress: progress,
      );
    });
  }

  testWidgets('shows saved section and calls onReady before total is known', (
    tester,
  ) async {
    await installExpandedBook(tester, section: 1, offset: 17, progress: .82);
    final anchor = library.find('reader')!;
    var ready = 0;
    await mount(
      tester,
      onReady: () {
        ready++;
        expect(page, findsOneWidget);
        expect(tester.renderObject<RenderBox>(page).hasSize, isTrue);
        expect(tester.getSize(page).height, greaterThan(0));
        expect(find.byType(CircularProgressIndicator), findsNothing);
      },
    );
    expect(ready, 0);
    await openReader(tester, settle: false);
    expect(ready, 1);
    expect(
      tester.widget<Text>(pageNumber).data,
      'Calculando p\u00e1ginas\u2026',
    );
    expect(
      find.descendant(of: page, matching: find.text('two.xhtml')),
      findsOneWidget,
    );
    await saveDebounce(tester);
    expectPage(tester, section: 1, offset: 17);
    expectSaved(anchor);
    tester.view.physicalSize = const Size(320, 568);
    await tester.pump();
    expect(
      tester.widget<Text>(pageNumber).data,
      'Calculando p\u00e1ginas\u2026',
    );
    await tester.pumpAndSettle();
    expect(ready, 1);
    expectPage(tester, section: 1, offset: 17);
    expect(tester.takeException(), isNull);
  });

  testWidgets('queues previous chapter while it is still unpaginated', (
    tester,
  ) async {
    await installExpandedBook(tester, section: 1, offset: 17, progress: .9);
    await mount(tester);
    await openReader(tester, settle: false);
    expect(
      tester.widget<Text>(pageNumber).data,
      'Calculando p\u00e1ginas\u2026',
    );
    await tester.tap(find.byTooltip('P\u00e1gina anterior'));
    await tester.pump();
    await saveDebounce(tester);
    final pagination = ReaderPagination.layout(
      document,
      size: tester.getSize(page),
      fontSize: 22,
      textScaler: TextScaler.noScaling,
      direction: TextDirection.ltr,
      locale: const Locale('en', 'US'),
    );
    final last = pagination.pages.lastWhere((page) => page.section == 0);
    expectPage(tester, section: 0, offset: last.start);
    expect(library.find('reader')!.textOffset, last.start);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await saveDebounce(tester);
    expectPage(tester, section: 1, offset: 0);
    await tester.drag(page, const Offset(150, 0));
    await saveDebounce(tester);
    expectPage(tester, section: 0, offset: last.start);
  });

  testWidgets('contents retargets pending work and resize keeps exact anchor', (
    tester,
  ) async {
    const offset = 1937;
    await installExpandedBook(
      tester,
      secondParagraphs: 120,
      section: 1,
      offset: offset,
      progress: .6,
    );
    final anchor = library.find('reader')!;
    var ready = 0;
    await mount(tester, onReady: () => ready++);
    await openReader(tester, settle: false);
    expect(
      tester.widget<Text>(pageNumber).data,
      'Calculando p\u00e1ginas\u2026',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('reader-chapter-remaining')))
          .data,
      'Calculando p\u00e1ginas do cap\u00edtulo\u2026',
    );
    tester.view.physicalSize = const Size(360, 640);
    await tester.pump();
    accessibility.value = const MediaQueryData(
      boldText: true,
      textScaler: TextScaler.linear(1.3),
    );
    await tester.pump();
    await saveDebounce(tester);
    expectPage(tester, section: 1, offset: offset);
    expectSaved(anchor);
    expect(ready, 1);

    // Start a new generation, then select a different section before it finishes.
    tester.view.physicalSize = const Size(430, 800);
    await tester.pump();
    await tester.tap(find.byTooltip('Sum\u00e1rio'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text(document.sections[0].title));
    await saveDebounce(tester);
    expectPage(tester, section: 0, offset: 0);
    expect(library.find('reader')!.section, 0);
    expect(library.find('reader')!.textOffset, 0);
    expect(ready, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'font changes cancel unfinished generations and keep saved offset',
    (tester) async {
      await installExpandedBook(
        tester,
        secondParagraphs: 120,
        section: 1,
        offset: 1937,
        progress: .7,
      );
      final anchor = library.find('reader')!;
      var ready = 0;
      await mount(tester, onReady: () => ready++);
      await openReader(tester, settle: false);
      await tester.tap(find.byTooltip('Ajustes de leitura'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byTooltip('Aumentar fonte'));
      await tester.pump();
      expect(
        tester.widget<Text>(pageNumber).data,
        'Calculando p\u00e1ginas\u2026',
      );
      await tester.tap(find.byTooltip('Aumentar fonte'));
      await tester.pump();
      tester.view.physicalSize = const Size(360, 640);
      await tester.pump();
      Navigator.of(tester.element(find.text('Fonte 26'))).pop();
      await saveDebounce(tester);
      expectPage(tester, section: 1, offset: 1937, fontSize: 26);
      expectSaved(anchor);
      expect(ready, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unmount cancels pagination without repeating ready notification',
    (tester) async {
      await installExpandedBook(tester, secondParagraphs: 120);
      var ready = 0;
      await mount(tester, onReady: () => ready++);
      await openReader(tester, settle: false);
      expect(ready, 1);
      tester.view.physicalSize = const Size(360, 640);
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(ready, 1);
      expect(tester.takeException(), isNull);
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  testWidgets('preserves anchor and progress through font, resize and reopen', (
    tester,
  ) async {
    await mount(tester);
    await openReader(tester);
    final initial = expectPage(tester, section: 0, offset: 0);
    await tester.tap(find.byTooltip('Pr\u00f3xima p\u00e1gina'));
    await saveDebounce(tester);
    final anchor = library.find('reader')!;
    expect(anchor.section, initial.pages[1].section);
    expect(anchor.textOffset, initial.pages[1].start);
    expect(anchor.textOffset, greaterThan(0));
    expect(anchor.progress, initial.progressAt(1));
    expect(anchor.progress, inExclusiveRange(0, 1));

    await tester.tap(find.byTooltip('Ajustes de leitura'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byTooltip('Aumentar fonte'));
      await tester.pumpAndSettle();
    }
    expect(find.text('Fonte 30'), findsOneWidget);
    Navigator.of(tester.element(find.text('Fonte 30'))).pop();
    await tester.pumpAndSettle();
    await saveDebounce(tester);
    final larger = expectPage(
      tester,
      section: anchor.section,
      offset: anchor.textOffset!,
      fontSize: 30,
    );
    expect(larger.pages.length, greaterThan(initial.pages.length));
    expectSaved(anchor);

    for (final size in [
      const Size(320, 568),
      const Size(568, 320),
      const Size(1280, 800),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      await saveDebounce(tester);
      expectPage(
        tester,
        section: anchor.section,
        offset: anchor.textOffset!,
        fontSize: 30,
      );
      expectSaved(anchor);
    }

    // Save again after returning to the original viewport.
    tester.view.physicalSize = const Size(430, 800);
    await tester.pump();
    await tester.tap(find.byTooltip('Salvar e voltar'));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderScreen), findsNothing);
    expectSaved(anchor);

    // A fresh Library must restore Hive state, not ReaderScreen's old cache.
    library.dispose();
    library = Library(box);
    await library.load();
    expectSaved(anchor);
    await openReader(tester);
    expectPage(tester, section: anchor.section, offset: anchor.textOffset!);
    await saveDebounce(tester);
    expectSaved(anchor);
  });

  testWidgets('save and leave flushes a page turn before its debounce fires', (
    tester,
  ) async {
    await mount(tester);
    await openReader(tester);
    await saveDebounce(tester);
    final pagination = expectPage(tester, section: 0, offset: 0);
    await tester.tap(find.byTooltip('Pr\u00f3xima p\u00e1gina'));
    await tester.pump();
    expect(library.find('reader')!.textOffset, 0);

    await tester.tap(find.byTooltip('Salvar e voltar'));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderScreen), findsNothing);
    final anchor = library.find('reader')!;
    expect(anchor.section, pagination.pages[1].section);
    expect(anchor.textOffset, pagination.pages[1].start);
    expect(anchor.progress, pagination.progressAt(1));
    expectSaved(anchor);

    library.dispose();
    library = Library(box);
    await library.load();
    await openReader(tester);
    expectPage(tester, section: anchor.section, offset: anchor.textOffset!);
    await saveDebounce(tester);
    expectSaved(anchor);
  });

  for (final variant in [
    (name: 'boldText', data: const MediaQueryData(boldText: true)),
    (
      name: 'lineHeight',
      data: const MediaQueryData(lineHeightScaleFactorOverride: 2.2),
    ),
    (
      name: 'letterSpacing',
      data: const MediaQueryData(letterSpacingOverride: 3),
    ),
    (name: 'wordSpacing', data: const MediaQueryData(wordSpacingOverride: 8)),
    (
      name: 'combined overrides and 200 percent text',
      data: const MediaQueryData(
        boldText: true,
        textScaler: TextScaler.linear(2),
        lineHeightScaleFactorOverride: 2.2,
        letterSpacingOverride: 3,
        wordSpacingOverride: 8,
      ),
    ),
  ]) {
    testWidgets('${variant.name} repaginates without overflow or clipping', (
      tester,
    ) async {
      await mount(tester, size: const Size(320, 568));
      await openReader(tester);
      await tester.tap(find.byTooltip('Pr\u00f3xima p\u00e1gina'));
      await saveDebounce(tester);
      final anchor = library.find('reader')!;

      // Change accessibility while mounted to exercise layout invalidation.
      accessibility.value = variant.data;
      await tester.pumpAndSettle();
      await saveDebounce(tester);
      final pagination = expectPage(
        tester,
        section: anchor.section,
        offset: anchor.textOffset!,
      );
      expectSaved(anchor);

      final next = pagination.locate(anchor.section, anchor.textOffset!) + 1;
      expect(next, lessThan(pagination.pages.length));
      await tester.tap(find.byTooltip('Pr\u00f3xima p\u00e1gina'));
      await saveDebounce(tester);
      expectPage(
        tester,
        section: pagination.pages[next].section,
        offset: pagination.pages[next].start,
      );
      expect(library.find('reader')!.textOffset, pagination.pages[next].start);
      expect(library.find('reader')!.progress, pagination.progressAt(next));
    });
  }

  testWidgets(
    'Space turns reader pages but activates focused settings button',
    (tester) async {
      await mount(tester);
      await openReader(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await saveDebounce(tester);
      final anchor = library.find('reader')!;
      expect(anchor.textOffset, greaterThan(0));
      final label = tester.widget<Text>(pageNumber).data;

      bool settingsHasFocus() =>
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<IconButton>()
              ?.tooltip ==
          'Ajustes de leitura';
      for (var i = 0; i < 12 && !settingsHasFocus(); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(settingsHasFocus(), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Fonte 22'), findsOneWidget);
      expect(tester.widget<Text>(pageNumber).data, label);
      await saveDebounce(tester);
      expectSaved(anchor);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed Hive save keeps reader open until discard is confirmed', (
    tester,
  ) async {
    await mount(tester);
    await openReader(tester);
    await saveDebounce(tester);
    final saved = library.find('reader')!;
    await tester.tap(find.byTooltip('Pr\u00f3xima p\u00e1gina'));
    await tester.pump();
    final unsavedLabel = tester.widget<Text>(pageNumber).data;
    await tester.runAsync(box.close);

    await tester.tap(find.byTooltip('Salvar e voltar'));
    await tester.pumpAndSettle();
    expect(find.text('Sair sem salvar?'), findsOneWidget);
    expect(library.find('reader')!.textOffset, saved.textOffset);
    expect(library.find('reader')!.progress, saved.progress);
    await tester.tap(find.text('Continuar lendo'));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderScreen), findsOneWidget);
    expect(tester.widget<Text>(pageNumber).data, unsavedLabel);
    expect(find.text('Tentar salvar posi\u00e7\u00e3o'), findsOneWidget);

    await tester.tap(find.byTooltip('Salvar e voltar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sair sem salvar'));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderScreen), findsNothing);
    expect(find.text('Open reader'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
