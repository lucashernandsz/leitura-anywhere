import 'dart:convert';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:leitura_anywhere/app.dart';
import 'package:leitura_anywhere/data/book.dart';
import 'package:leitura_anywhere/data/catalog.dart';
import 'package:leitura_anywhere/data/catalog_settings.dart';
import 'package:leitura_anywhere/data/library.dart';
import 'package:leitura_anywhere/reader/document_cache.dart';
import 'package:leitura_anywhere/reader/reader_screen.dart';
import 'package:leitura_anywhere/ui/desk_book.dart';

import 'support/epub_fixture.dart';

void main() {
  late Library library;
  late CatalogService catalog;
  late CatalogSettings catalogSettings;
  late MockClient client;
  late int remoteCount;
  late List<Uri> requests;

  setUp(() async {
    // Disk persistence is covered separately, outside the widget test clock.
    library = Library(await Hive.openBox<dynamic>('ui', bytes: Uint8List(0)));
    await library.load();
    catalogSettings = CatalogSettings(
      await Hive.openBox<dynamic>('ui-settings', bytes: Uint8List(0)),
    );
    remoteCount = 1;
    requests = [];
    client = MockClient((request) async {
      requests.add(request.url);
      if (request.url.path.endsWith('.epub')) {
        return http.Response.bytes(fixtureEpub(), 200);
      }
      return http.Response(
        jsonEncode({
          'next': null,
          'results': List.generate(
            remoteCount,
            (index) => {
              'id': index + 1,
              'title': index == 0 ? 'Uma história' : 'Livro ${index + 1}',
              'authors': [
                {'name': 'Uma autora'},
              ],
              'subjects': ['Fiction'],
              'formats': {
                'application/epub+zip': 'https://www.gutenberg.org/book.epub',
              },
            },
          ),
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    catalog = CatalogService(client: client);
  });

  tearDown(() async {
    library.dispose();
    catalog.dispose();
    client.close();
    await Hive.close();
  });

  Future<void> app(WidgetTester tester, Size size, {double scale = 1}) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      // Finish speculative work in its original test clock before the next test.
      var prepared = false;
      Future.wait(
        library.books.map((book) => EpubDocumentCache.warm(book.bytes)),
      ).then((_) => prepared = true);
      for (var frame = 0; frame < 200 && !prepared; frame++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(prepared, isTrue);
      EpubDocumentCache.resetForTesting();
    });
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      LeituraApp(
        library: library,
        catalog: catalog,
        catalogSettings: catalogSettings,
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openReader(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const ValueKey('desk-cover')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('desk-cover')));
    for (
      var i = 0;
      i < 80 && find.byKey(const ValueKey('reader-page')).evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reader-page')), findsOneWidget);
  }

  String pageLabel(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('reader-page-number')))
      .data!;

  for (final size in [
    const Size(320, 568),
    const Size(430, 952),
    const Size(1280, 800),
    const Size(1920, 1080),
    const Size(844, 390),
  ]) {
    testWidgets('desk fills the viewport and emphasizes the book at $size', (
      tester,
    ) async {
      await tester.runAsync(
        () => library.add(
          Book(
            id: 'desk',
            title: 'O livro',
            author: 'Greg McKeown',
            source: 'Teste',
          ),
          fixtureEpub(),
        ),
      );
      await app(tester, size);
      final cover = tester.getRect(find.byKey(const ValueKey('desk-cover')));
      final title = tester.getRect(find.byKey(const ValueKey('desk-title')));
      final author = tester.getRect(find.byKey(const ValueKey('desk-author')));
      final surface = tester.getRect(
        find.byKey(const ValueKey('desk-surface')),
      );
      expect(surface.width, size.width);
      expect(surface.height, greaterThanOrEqualTo(size.height - 84));
      expect(title.top, closeTo(72, 0.01));
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('desk-title')))
            .style!
            .fontSize,
        size.width >= 600 ? 38 : 30,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('desk-author')))
            .style!
            .fontSize,
        size.width >= 600 ? 20 : 18,
      );
      expect(cover.center.dx, closeTo(size.width / 2, 0.01));
      expect(title.center.dx, closeTo(cover.center.dx, 0.01));
      expect(author.center.dx, closeTo(cover.center.dx, 0.01));
      expect(find.text('SUA MESA'), findsNothing);
      expect(find.text('EPUB · Disponível offline'), findsNothing);
      expect(find.text('Começar a ler'), findsNothing);
      expect(find.text('Continuar leitura'), findsNothing);
      expect(find.text('Sem pressa. Só mais um capítulo.'), findsNothing);
      expect(find.byTooltip('Ações do livro'), findsNothing);
      expect(find.text('0% lido'), findsOneWidget);
      expect(find.text('Importar EPUB'), findsNothing);
      expect(find.byIcon(Icons.space_dashboard), findsNothing);
      expect(
        tester.getRect(find.text('Sua Mesa')).bottom,
        closeTo(size.height - 43, 1),
      );
      if (size == const Size(430, 952)) {
        expect(title.height, closeTo(37.5, 1));
        expect(author.top, closeTo(title.bottom + 10, 0.01));
        expect(author.height, closeTo(25.2, 1));
        expect(cover.top, closeTo(author.bottom + 24, 0.01));
        expect(cover.width, closeTo(382, 0.01));
        expect(cover.height, closeTo(534.8, 0.01));
      }
      await tester.ensureVisible(find.byKey(const ValueKey('desk-cover')));
      await tester.drag(
        find.byKey(const ValueKey('desk-cover')),
        const Offset(-120, 0),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('desk-title'))).data,
        'O livro',
      );
      await tester.longPress(find.byKey(const ValueKey('desk-cover')));
      await tester.pumpAndSettle();
      expect(find.text('Retirar da Sua Mesa'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('desk respects safe areas without moving the heading down', (
    tester,
  ) async {
    await tester.runAsync(
      () => library.add(
        Book(id: 'safe', title: 'Livro', author: 'Autora', source: 'Teste'),
        fixtureEpub(),
      ),
    );
    tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
    addTearDown(tester.view.resetPadding);
    await app(tester, const Size(430, 932));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('desk-title'))).dy,
      closeTo(72, 0.01),
    );
    expect(tester.getRect(find.text('Sua Mesa')).bottom, lessThan(932 - 34));
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(320, 568),
    const Size(430, 952),
    const Size(1280, 800),
  ]) {
    testWidgets('empty navigation works without overflow at $size', (
      tester,
    ) async {
      await app(tester, size);
      expect(find.text('Um livro.\nUm momento seu.'), findsOneWidget);
      await tester.tap(find.text('Biblioteca').last);
      await tester.pumpAndSettle();
      expect(find.text('Sua próxima história\ncomeça aqui.'), findsOneWidget);
      expect(find.text('Importar EPUB'), findsNothing);
      await tester.tap(find.text('Descobrir').last);
      await tester.pumpAndSettle();
      expect(find.text('Uma história'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [
    const Size(320, 568),
    const Size(430, 952),
    const Size(1280, 800),
  ]) {
    testWidgets('populated navigation fits large text at $size', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await library.add(
          Book(
            id: 'long',
            title:
                'Uma longa historia com um titulo extenso para testar miniaturas',
            author: 'Uma autora com nome muito extenso',
            source: 'Teste',
          ),
          fixtureEpub(),
        );
        await library.setOnDesk('long', true);
      });
      await app(tester, size, scale: 2);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Biblioteca').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('library-cover-long')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Excluir da Biblioteca'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Descobrir').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('library matches pen grid, filters, navigation and actions', (
    tester,
  ) async {
    await tester.runAsync(() async {
      for (var index = 1; index <= 9; index++) {
        await library.add(
          Book(
            id: '$index',
            title: 'Livro $index',
            author: 'Autor',
            source: 'Teste',
          ),
          fixtureEpub(),
        );
      }
    });
    await app(tester, const Size(430, 952));
    await tester.tap(find.text('Biblioteca').last);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const ValueKey('library-heading'))),
      const Rect.fromLTWH(24, 74, 382, 33),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('library-filters'))),
      const Rect.fromLTWH(24, 123, 382, 40),
    );
    final books = library.books;
    for (var index = 0; index < 9; index++) {
      final cover = tester.getRect(
        find.byKey(ValueKey('library-cover-${books[index].book.id}')),
      );
      expect(
        cover,
        Rect.fromLTWH(52 + index % 3 * 117, 211 + index ~/ 3 * 172, 92, 130),
      );
    }
    expect(find.byType(NavigationBar), findsNothing);
    expect(tester.getTopLeft(find.text('Biblioteca').last).dy, closeTo(894, 1));
    await tester.tap(find.text('Lendo'));
    await tester.pumpAndSettle();
    expect(find.text('Você ainda não começou uma leitura.'), findsOneWidget);
    await tester.tap(find.text('Todos'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('library-cover-${books.first.book.id}')),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const ValueKey('book-panel'))),
      const Rect.fromLTWH(14, 537, 402, 397),
    );
    expect(find.text('Agrupar com outro livro'), findsOneWidget);
    expect(find.text('Ler agora'), findsOneWidget);
    expect(find.text('Excluir da Biblioteca'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('discover matches pen search, categories and cover grid', (
    tester,
  ) async {
    remoteCount = 9;
    await app(tester, const Size(430, 952));
    await tester.tap(find.text('Descobrir').last);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const ValueKey('discover-heading'))),
      const Rect.fromLTWH(24, 74, 382, 48),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('discover-search'))),
      const Rect.fromLTWH(24, 126, 382, 48),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('discover-categories'))),
      const Rect.fromLTWH(24, 190, 382, 36),
    );
    for (var index = 0; index < 9; index++) {
      expect(
        tester.getRect(
          find.byKey(ValueKey('discover-cover-gutenberg:${index + 1}')),
        ),
        Rect.fromLTWH(37 + index % 3 * 122, 242 + index ~/ 3 * 172, 112, 160),
      );
    }
    expect(find.text('HISTÓRIAS QUE FICAM'), findsNothing);
    expect(find.text('EPUB'), findsNothing);
    expect(requests.last.queryParameters['topic'], 'psychology');
    await tester.tap(find.text('Carreira'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(requests.last.queryParameters['topic'], 'business');
    await tester.enterText(find.byType(TextField), 'Machado');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(requests.last.queryParameters['search'], 'Machado');
    await tester.tap(find.byTooltip('Limpar busca'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(requests.last.queryParameters.containsKey('search'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('group actions expose members and allow ungrouping', (
    tester,
  ) async {
    await tester.runAsync(() async {
      for (final id in ['a', 'b']) {
        await library.add(
          Book(id: id, title: 'Livro $id', author: 'Autor', source: 'Teste'),
          fixtureEpub(),
        );
      }
    });
    await app(tester, const Size(430, 952));
    await tester.tap(find.text('Biblioteca').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-cover-b')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agrupar com outro livro'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Livro a'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(library.groupFor('b').length, 2);
    expect(find.byKey(const ValueKey('library-cover-a')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('library-cover-b')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ver livros do grupo'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Livro a'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Desagrupar este livro'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(library.groupFor('a').length, 1);
    expect(library.groupFor('b').length, 1);
    expect(find.byKey(const ValueKey('library-cover-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('library-cover-b')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long press drag groups books', (tester) async {
    await tester.runAsync(() async {
      for (final id in ['a', 'b']) {
        await library.add(
          Book(id: id, title: 'Livro $id', author: 'Autor', source: 'Teste'),
          fixtureEpub(),
        );
      }
    });
    await app(tester, const Size(430, 952));
    await tester.tap(find.text('Biblioteca').last);
    await tester.pumpAndSettle();
    final target = tester.getCenter(
      find.byKey(const ValueKey('library-cover-a')),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('library-cover-b'))),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.up();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(library.groupFor('a').length, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('discover scrolls with large text and mobile keyboard', (
    tester,
  ) async {
    await app(tester, const Size(320, 568), scale: 2);
    await tester.tap(find.text('Descobrir').last);
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 250);
    addTearDown(tester.view.resetViewInsets);
    await tester.showKeyboard(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'Livro');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
    testWidgets(
      'desk switches books by swipe without visible controls with $kind',
      (tester) async {
        await tester.runAsync(() async {
          for (final id in ['first', 'second', 'third']) {
            await library.add(
              Book(id: id, title: id, author: 'Uma autora', source: 'Teste'),
              fixtureEpub(),
            );
          }
        });
        await app(tester, const Size(430, 952));
        final title = find.byKey(const ValueKey('desk-title'));
        final initial = tester.widget<Text>(title).data;
        await tester.drag(
          find.byKey(const ValueKey('desk-cover')),
          const Offset(-30, 0),
          kind: kind,
        );
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(title).data, initial);
        await tester.drag(
          find.byKey(const ValueKey('desk-cover')),
          const Offset(-160, 0),
          kind: kind,
        );
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(title).data, isNot(initial));
        await tester.drag(
          find.byKey(const ValueKey('desk-cover')),
          const Offset(160, 0),
          kind: kind,
        );
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(title).data, initial);
        await tester.drag(
          find.byKey(const ValueKey('desk-cover')),
          const Offset(160, 0),
          kind: kind,
        );
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(title).data, isNot(initial));
        await tester.drag(
          find.byKey(const ValueKey('desk-cover')),
          const Offset(-160, 0),
          kind: kind,
        );
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(title).data, initial);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(title).data, isNot(initial));
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(title).data, initial);
        expect(find.byTooltip('Próximo livro'), findsNothing);
        expect(find.byTooltip('Livro anterior'), findsNothing);
        expect(find.textContaining('Arraste para girar'), findsNothing);
        expect(find.textContaining(RegExp(r'^\d+ / \d+$')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'desk supports swiping outside the cover and ignores canceled drags',
    (tester) async {
      await tester.runAsync(() async {
        for (final id in ['first', 'second']) {
          await library.add(
            Book(id: id, title: id, author: 'Autora', source: 'Teste'),
            fixtureEpub(),
          );
        }
      });
      await app(tester, const Size(430, 952));
      final title = find.byKey(const ValueKey('desk-title'));
      final initial = tester.widget<Text>(title).data;
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('desk-cover'))),
      );
      await gesture.moveBy(const Offset(-100, 0));
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(title).data, initial);
      await tester.dragFrom(const Offset(250, 35), const Offset(-160, 0));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(title).data, isNot(initial));
    },
  );

  testWidgets('vertical drag rotates the book instead of scrolling the desk', (
    tester,
  ) async {
    await tester.runAsync(
      () => library.add(
        Book(id: 'vertical', title: 'Livro', author: 'Autora', source: 'Teste'),
        fixtureEpub(),
      ),
    );
    await tester.runAsync(
      () => library.add(
        Book(id: 'another', title: 'Outro', author: 'Autora', source: 'Teste'),
        fixtureEpub(),
      ),
    );
    await app(tester, const Size(320, 568), scale: 2);
    List<List<double>> transforms() => tester
        .widgetList<Transform>(
          find.descendant(
            of: find.byType(DeskBook),
            matching: find.byType(Transform),
          ),
        )
        .map((widget) => widget.transform.storage.toList())
        .toList();
    final cover = find.byKey(const ValueKey('desk-cover'));
    await tester.ensureVisible(cover);
    await tester.pumpAndSettle();
    final initial = transforms();
    final before = tester.getTopLeft(cover);
    final title = tester
        .widget<Text>(find.byKey(const ValueKey('desk-title')))
        .data;
    final gesture = await tester.startGesture(tester.getCenter(cover));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, -8));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(transforms(), isNot(equals(initial)));
    expect(tester.getTopLeft(cover), before);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('desk-title'))).data,
      title,
    );
    await tester.drag(cover, const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('desk-title'))).data,
      isNot(title),
    );
    expect(transforms(), equals(initial));
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(320, 568),
    const Size(430, 952),
    const Size(1280, 800),
  ]) {
    testWidgets('desk swipe works with large text at $size', (tester) async {
      await tester.runAsync(() async {
        for (final id in ['first', 'second']) {
          await library.add(
            Book(id: id, title: id, author: 'Uma autora', source: 'Teste'),
            fixtureEpub(),
          );
        }
      });
      await app(tester, size, scale: 2);
      final title = find.byKey(const ValueKey('desk-title'));
      final initial = tester.widget<Text>(title).data;
      final cover = find.byKey(const ValueKey('desk-cover'));
      await tester.ensureVisible(cover);
      await tester.pumpAndSettle();
      await tester.drag(cover, const Offset(-120, 0));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(title).data, isNot(initial));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('download is validated, stored and displayed in library', (
    tester,
  ) async {
    await app(tester, const Size(430, 952));
    await tester.tap(find.text('Descobrir').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Uma história').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Baixar para a biblioteca'));
    for (var i = 0; i < 40 && library.books.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(library.books, hasLength(1));
    expect(find.byType(SnackBar), findsNothing);
    await tester.tap(find.text('Biblioteca').last);
    await tester.pumpAndSettle();
    expect(find.text('Uma história'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reader turns pages, saves progress on desk and restores', (
    tester,
  ) async {
    await tester.runAsync(
      () => library.add(
        Book(
          id: 'test',
          title: 'Uma história',
          author: 'Uma autora',
          source: 'Teste',
        ),
        fixtureEpub(),
      ),
    );
    await app(tester, const Size(430, 952));
    await openReader(tester);
    expect(pageLabel(tester), startsWith('Página 1 de '));
    expect(find.text('1 de 2 seções'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(ReaderScreen),
        matching: find.byType(SingleChildScrollView),
      ),
      findsNothing,
    );
    final remaining = tester
        .widget<Text>(find.byKey(const ValueKey('reader-chapter-remaining')))
        .data!;
    expect(remaining, contains('página'));
    await tester.tap(find.byTooltip('Próxima página'));
    await tester.pumpAndSettle();
    final savedPage = pageLabel(tester);
    expect(savedPage, startsWith('Página 2 de '));
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('reader-chapter-remaining')))
          .data,
      isNot(remaining),
    );
    await tester.tap(find.byTooltip('Salvar e voltar'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(library.books.single.textOffset, greaterThan(0));
    expect(library.books.single.progress, inExclusiveRange(0, 1));
    expect(
      find.text('${(library.books.single.progress! * 100).floor()}% lido'),
      findsOneWidget,
    );
    await openReader(tester);
    expect(pageLabel(tester), savedPage);
    await tester.tap(find.byTooltip('Sumário'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Depois'));
    await tester.pumpAndSettle();
    expect(find.text('Última página do capítulo'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find
                .ancestor(
                  of: find.byTooltip('Próxima página'),
                  matching: find.byType(IconButton),
                )
                .first,
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('Salvar e voltar'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(library.books.single.section, 1);
    expect(library.books.single.progress, 1);
    expect(find.text('100% lido'), findsOneWidget);
    await tester.tap(find.text('Biblioteca').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lendo'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('library-cover-test')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  for (final size in [
    const Size(320, 568),
    const Size(568, 320),
    const Size(1280, 800),
  ]) {
    testWidgets('reader paginates at $size with 200 percent text', (
      tester,
    ) async {
      await tester.runAsync(
        () => library.add(
          Book(
            id: 'pages',
            title: 'Uma história',
            author: 'Autora',
            source: 'Teste',
          ),
          fixtureEpub(),
        ),
      );
      await app(tester, size, scale: 2);
      await openReader(tester);
      final first = pageLabel(tester);
      await tester.drag(
        find.byKey(const ValueKey('reader-page')),
        const Offset(-160, 0),
      );
      await tester.pumpAndSettle();
      expect(pageLabel(tester), isNot(first));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(pageLabel(tester), first);
      await tester.tap(find.byTooltip('Ajustes de leitura'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Aumentar fonte'));
      await tester.pumpAndSettle();
      expect(find.text('Fonte 24'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
}
