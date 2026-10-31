import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:leitura_anywhere/data/book.dart';
import 'package:leitura_anywhere/data/library.dart';
import 'package:leitura_anywhere/reader/book_opening_screen.dart';
import 'package:leitura_anywhere/reader/document_cache.dart';
import 'package:leitura_anywhere/reader/epub_document.dart';
import 'package:leitura_anywhere/reader/reader_screen.dart';
import 'package:leitura_anywhere/ui/desk_book.dart';

import 'support/epub_fixture.dart';

void main() {
  late Box<dynamic> box;
  late Library library;
  late Completer<EpubDocument> preparation;
  late LocalBook local;
  late int opened;
  var initialized = false;

  EpubDocument document() => EpubDocument(
    title: 'Livro',
    author: 'Autora',
    sections: [
      EpubSection(
        title: 'Capitulo',
        blocks: const [EpubBlock(text: 'As primeiras palavras do livro.')],
      ),
    ],
  );

  setUp(() async {
    box = await Hive.openBox<dynamic>('book-opening', bytes: Uint8List(0));
    library = Library(box);
    await library.load();
    await library.add(
      Book(id: 'opening', title: 'Livro', author: 'Autora', source: 'Teste'),
      fixtureEpub(),
    );
    local = library.find('opening')!;
    initialized = false;
    opened = 0;
  });

  tearDown(() async {
    if (!preparation.isCompleted) preparation.complete(document());
    await Future<void>.delayed(Duration.zero);
    EpubDocumentCache.resetForTesting();
    library.dispose();
    await box.close();
  });

  Future<void> mount(
    WidgetTester tester, {
    bool reducedMotion = false,
    bool ready = false,
    Size size = const Size(430, 800),
  }) async {
    if (!initialized) {
      initialized = true;
      preparation = Completer<EpubDocument>();
      EpubDocumentCache.resetForTesting(parser: (_) => preparation.future);
      if (ready) preparation.complete(document());
      addTearDown(() async {
        if (!preparation.isCompleted) preparation.complete(document());
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    }
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reducedMotion),
          child: child!,
        ),
        home: BookOpeningScreen(
          library: library,
          local: local,
          origin: const BookOpeningOrigin(
            Rect.fromLTWH(60, 180, 280, 392),
            0.4,
            -0.2,
          ),
          onOpened: () => opened++,
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }

  for (final size in [const Size(320, 568), const Size(1280, 800)]) {
    testWidgets('cover reveals real text in 900ms when ready at $size', (
      tester,
    ) async {
      await mount(tester, size: size, ready: true);
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.byKey(const ValueKey('reader-page')), findsOneWidget);
      expect(find.byType(DeskBook), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 550));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 270));
      await tester.pump();
      expect(find.byType(DeskBook), findsNothing);
      expect(find.text('As primeiras palavras do livro.'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 16));
      expect(opened, 1);
      expect(
        tester
            .widget<ReaderScreen>(find.byType(ReaderScreen))
            .focusNode!
            .hasFocus,
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  testWidgets('slow preparation holds cover, then reveals real text', (
    tester,
  ) async {
    await mount(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Preparando sua leitura...'), findsOneWidget);
    expect(find.byType(DeskBook), findsOneWidget);
    expect(opened, 0);
    preparation.complete(document());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    for (var frame = 0; frame < 5; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 270));
    await tester.pump();
    expect(find.byType(DeskBook), findsNothing);
    expect(opened, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('reduced motion skips cover and animation delay', (tester) async {
    await mount(tester, reducedMotion: true, ready: true);
    for (var frame = 0; frame < 5; frame++) {
      await tester.pump();
    }
    expect(find.byType(DeskBook), findsNothing);
    expect(find.byType(ReaderScreen), findsOneWidget);
    expect(opened, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('parser error reveals retry instead of holding cover', (
    tester,
  ) async {
    await mount(tester);
    preparation.completeError(const FormatException('EPUB invalido.'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.pump();
    expect(find.text('EPUB invalido.'), findsOneWidget);
    expect(find.text('Tentar novamente'), findsOneWidget);
    expect(find.byType(DeskBook), findsNothing);
    expect(opened, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('disposing during preparation cancels animation safely', (
    tester,
  ) async {
    await mount(tester);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpWidget(const SizedBox.shrink());
    preparation.complete(document());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(opened, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('enabling reduced motion finishes a ready opening once', (
    tester,
  ) async {
    await mount(tester, ready: true);
    for (var frame = 0; frame < 5; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(opened, 0);
    await mount(tester, reducedMotion: true);
    await tester.pump();
    expect(find.byType(DeskBook), findsNothing);
    expect(opened, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('successful retry reports opening after parser failure', (
    tester,
  ) async {
    await mount(tester);
    preparation.completeError(const FormatException('EPUB invalido.'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    EpubDocumentCache.resetForTesting(parser: (_) async => document());
    await tester.tap(find.text('Tentar novamente'));
    for (var frame = 0; frame < 5; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byKey(const ValueKey('reader-page')), findsOneWidget);
    expect(opened, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
