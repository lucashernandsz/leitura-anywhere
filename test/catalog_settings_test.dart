import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:leitura_anywhere/app.dart';
import 'package:leitura_anywhere/data/book.dart';
import 'package:leitura_anywhere/data/catalog.dart';
import 'package:leitura_anywhere/data/catalog_settings.dart';
import 'package:leitura_anywhere/data/library.dart';

import 'support/epub_fixture.dart';

/// Exercises the UI contract without Gutendex JSON, Gutenberg IDs or HTTP.
class TestCatalog implements BookCatalog {
  final book = Book(
    id: 'another-source:book',
    title: 'Livro de outra fonte',
    author: 'Autora',
    source: 'Outra fonte',
    downloadUrl: 'https://example.test/book.epub',
  );
  int searches = 0;
  int downloads = 0;

  @override
  String get displayName => 'Outra fonte';

  @override
  String get usageNotice => 'Permissoes da outra fonte.';

  @override
  Future<CatalogPage> search({
    String query = '',
    String? topic,
    int page = 1,
  }) async {
    searches++;
    return CatalogPage(books: [book], hasNext: false, page: page);
  }

  @override
  Future<Uint8List> download(
    Book book, {
    void Function(double?)? onProgress,
  }) async {
    downloads++;
    return fixtureEpub();
  }

  @override
  void dispose() {}
}

void main() {
  test('site configuration persists separately from the library', () async {
    final directory = await Directory.systemTemp.createTemp(
      'catalog-settings-',
    );
    try {
      Hive.init(directory.path);
      var box = await Hive.openBox<dynamic>('settings');
      var settings = CatalogSettings(box);
      expect(settings.zLibrarySite, isNull);
      await settings.saveZLibrarySite('  https://EXAMPLE.test:443/  ');
      expect(box.toMap(), {'zLibrarySite': 'https://example.test'});
      await box.close();

      box = await Hive.openBox<dynamic>('settings');
      settings = CatalogSettings(box);
      expect(settings.zLibrarySite, Uri.parse('https://example.test'));
      await settings.removeZLibrarySite();
      expect(settings.zLibrarySite, isNull);
      expect(box.isEmpty, isTrue);
    } finally {
      await Hive.close();
      await directory.delete(recursive: true);
    }
  });

  group('session restoration intent', () {
    const restoreKey = 'zLibrarySessionRestorationAllowed';
    late Directory directory;
    late Box<dynamic> box;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('catalog-session-');
      Hive.init(directory.path);
      box = await Hive.openBox<dynamic>('settings');
    });

    tearDown(() async {
      await Hive.close();
      await directory.delete(recursive: true);
    });

    test(
      'only an explicit boolean permission survives closing and reopening',
      () async {
        var settings = CatalogSettings(box);
        expect(await settings.canRestoreZLibrarySession(), isFalse);
        await settings.saveZLibrarySite('https://example.test');
        await settings.setZLibrarySessionRestoration(true);
        expect(box.toMap(), {
          'zLibrarySite': 'https://example.test',
          restoreKey: true,
        });
        await box.close();
        box = await Hive.openBox<dynamic>('settings');
        settings = CatalogSettings(box);
        expect(await settings.canRestoreZLibrarySession(), isTrue);
        await settings.setZLibrarySessionRestoration(false);
        await settings.removeZLibrarySite();
        await box.close();
        box = await Hive.openBox<dynamic>('settings');
        expect(await CatalogSettings(box).canRestoreZLibrarySession(), isFalse);
        expect(box.toMap(), {restoreKey: false});
      },
    );

    test(
      'absent or malformed permission never authorizes restoration',
      () async {
        for (final value in [null, false, 'true', 1, <String, dynamic>{}]) {
          await box.put(restoreKey, value);
          expect(
            await CatalogSettings(box).canRestoreZLibrarySession(),
            isFalse,
          );
        }
      },
    );

    test(
      'unavailable storage denies reads and propagates write failures',
      () async {
        final settings = CatalogSettings.lazy(
          () async => throw StateError('unavailable storage'),
        );
        expect(await settings.canRestoreZLibrarySession(), isFalse);
        await expectLater(
          settings.setZLibrarySessionRestoration(false),
          throwsStateError,
        );
        expect(await settings.canRestoreZLibrarySession(), isFalse);
        await box.put(restoreKey, true);
        final closed = CatalogSettings(box);
        await box.close();
        expect(await closed.canRestoreZLibrarySession(), isFalse);
      },
    );

    test(
      'writes serialize through lazy opening and last intent wins',
      () async {
        await box.put(restoreKey, true);
        final opening = Completer<Box<dynamic>>();
        final settings = CatalogSettings.lazy(() => opening.future);
        final enable = settings.setZLibrarySessionRestoration(true);
        final disable = settings.setZLibrarySessionRestoration(false);
        expect(await settings.canRestoreZLibrarySession(), isFalse);
        opening.complete(box);
        await Future.wait([enable, disable]);
        expect(box.get(restoreKey), isFalse);
        expect(await settings.canRestoreZLibrarySession(), isFalse);
        await settings.setZLibrarySessionRestoration(true);
        expect(await settings.canRestoreZLibrarySession(), isTrue);
      },
    );

    test('logout intent invalidates a read awaiting storage', () async {
      await box.put(restoreKey, true);
      final opening = Completer<Box<dynamic>>();
      final settings = CatalogSettings.lazy(() => opening.future);
      final read = settings.canRestoreZLibrarySession();
      final disable = settings.setZLibrarySessionRestoration(false);
      opening.complete(box);
      expect(await read, isFalse);
      await disable;
      expect(box.get(restoreKey), isFalse);
    });

    test('a failed write does not skip the next queued logout', () async {
      final opening = Completer<void>();
      var attempts = 0;
      final settings = CatalogSettings.lazy(() async {
        if (++attempts == 1) {
          await opening.future;
          throw StateError('first open failed');
        }
        return box;
      });
      final enable = settings.setZLibrarySessionRestoration(true);
      final failed = expectLater(enable, throwsStateError);
      final disable = settings.setZLibrarySessionRestoration(false);
      opening.complete();
      await failed;
      await disable;
      expect(attempts, 2);
      expect(box.get(restoreKey), isFalse);
      expect(await settings.canRestoreZLibrarySession(), isFalse);
    });
  });

  for (final value in [
    '',
    'example.test',
    'http://example.test',
    'https://user:password@example.test',
    'https://@example.test',
    'https://example.test/login',
    'https://example.test?token=private',
    'https://example.test?',
    'https://example.test#private',
    'https://example.test#',
    'https://example.test:8443',
    'https://example.test:invalid',
    'https://localhost',
    'https://-invalid.test',
    'https://invalid..test',
    'https://invalid_host.test',
  ]) {
    test('rejects unsafe or non-origin site: $value', () {
      expect(() => CatalogSettings.parseSite(value), throwsFormatException);
    });
  }

  test('invalid input preserves saved configuration', () async {
    final box = await Hive.openBox<dynamic>('validation', bytes: Uint8List(0));
    try {
      final settings = CatalogSettings(box);
      await settings.saveZLibrarySite('https://example.test');
      await expectLater(
        settings.saveZLibrarySite('https://example.test/?token=private'),
        throwsFormatException,
      );
      expect(settings.zLibrarySite, Uri.parse('https://example.test'));
      expect(box.toMap(), {'zLibrarySite': 'https://example.test'});
      await box.put('zLibrarySite', 'https://example.test?token=untrusted');
      expect(settings.zLibrarySite, isNull);
      // Do not erase an unrecognized persisted record implicitly.
      expect(box.get('zLibrarySite'), contains('untrusted'));
    } finally {
      await box.close();
    }
  });

  group('source configuration UI', () {
    late Library library;
    late CatalogSettings settings;
    late TestCatalog catalog;

    setUp(() async {
      library = Library(
        await Hive.openBox<dynamic>('library-ui', bytes: Uint8List(0)),
      );
      await library.load();
      settings = CatalogSettings(
        await Hive.openBox<dynamic>('settings-ui', bytes: Uint8List(0)),
      );
      catalog = TestCatalog();
    });

    tearDown(() async {
      library.dispose();
      await Hive.close();
    });

    Future<void> openSettings(
      WidgetTester tester,
      Size size,
      double scale,
    ) async {
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
          catalogSettings: settings,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Descobrir').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Fontes e contas'));
      await tester.pumpAndSettle();
    }

    for (final size in [
      const Size(320, 568),
      const Size(430, 952),
      const Size(1280, 800),
    ]) {
      testWidgets('saves, restores and removes site at $size with large text', (
        tester,
      ) async {
        await openSettings(tester, size, 2);
        expect(find.text('Integra\u00e7\u00e3o pendente'), findsOneWidget);
        expect(
          find.textContaining('Outra fonte continua ativo'),
          findsOneWidget,
        );
        expect(find.byType(TextFormField), findsOneWidget);
        final field = find.byKey(const ValueKey('zlibrary-site'));
        await tester.ensureVisible(field);
        await tester.enterText(field, 'https://EXAMPLE.test/');
        tester.testTextInput.hide();
        final save = find.text('Salvar endere\u00e7o');
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(settings.zLibrarySite, Uri.parse('https://example.test'));
        expect(catalog.searches, 1);
        expect(catalog.downloads, 0);
        expect(library.books, isEmpty);
        expect(
          find.textContaining('A conta ainda n\u00e3o foi conectada'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);

        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Fontes e contas'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextFormField>(field).controller!.text,
          'https://example.test',
        );
        final remove = find.text('Remover endere\u00e7o');
        await tester.ensureVisible(remove);
        await tester.tap(remove);
        await tester.pumpAndSettle();
        expect(settings.zLibrarySite, isNull);
        expect(find.text('Remover endere\u00e7o'), findsNothing);
        expect(catalog.searches, 1);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('invalid site never saves or invokes the catalog', (
      tester,
    ) async {
      await openSettings(tester, const Size(430, 952), 1);
      final field = find.byKey(const ValueKey('zlibrary-site'));
      await tester.ensureVisible(field);
      await tester.enterText(field, 'https://example.test?password=secret');
      tester.testTextInput.hide();
      await tester.ensureVisible(find.text('Salvar endere\u00e7o'));
      await tester.tap(find.text('Salvar endere\u00e7o'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Use somente o endere\u00e7o HTTPS'),
        findsOneWidget,
      );
      expect(settings.zLibrarySite, isNull);
      expect(catalog.searches, 1);
      expect(catalog.downloads, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'unavailable settings do not block the app and can be retried',
      (tester) async {
        var attempts = 0;
        settings = CatalogSettings.lazy(() async {
          if (++attempts == 1) throw StateError('private storage detail');
          return Hive.openBox<dynamic>('retry-settings', bytes: Uint8List(0));
        });
        await tester.pumpWidget(
          LeituraApp(
            library: library,
            catalog: catalog,
            catalogSettings: settings,
          ),
        );
        await tester.pumpAndSettle();
        expect(attempts, 0);
        expect(catalog.searches, 1);
        await tester.tap(find.text('Descobrir').last);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Fontes e contas'));
        await tester.pumpAndSettle();
        expect(attempts, 1);
        expect(
          find.textContaining('continuam dispon\u00edveis'),
          findsOneWidget,
        );
        expect(find.textContaining('private storage detail'), findsNothing);
        expect(find.byType(TextFormField), findsNothing);
        await tester.ensureVisible(find.text('Tentar novamente'));
        await tester.tap(find.text('Tentar novamente'));
        await tester.pumpAndSettle();
        expect(attempts, 2);
        expect(find.byType(TextFormField), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('discover-cover-another-source:book')),
          findsOneWidget,
        );
        expect(catalog.searches, 1);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'another provider supports details, download and local library',
      (tester) async {
        await openSettings(tester, const Size(430, 952), 1);
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('discover-cover-another-source:book')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Permissoes da outra fonte.'), findsOneWidget);
        expect(find.textContaining('Estados Unidos'), findsNothing);
        await tester.tap(find.text('Baixar para a biblioteca'));
        for (var i = 0; i < 40 && library.books.isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();
        expect(catalog.downloads, 1);
        expect(library.books.single.book.id, 'another-source:book');
        expect(library.books.single.book.source, 'Outra fonte');
        expect(tester.takeException(), isNull);
      },
    );

    for (final remove in [false, true]) {
      testWidgets(
        'storage failure during ${remove ? 'remove' : 'save'} is safe',
        (tester) async {
          final box = await Hive.openBox<dynamic>(
            'failing-settings',
            bytes: Uint8List(0),
          );
          settings = CatalogSettings(box);
          await tester.runAsync(
            () => settings.saveZLibrarySite('https://example.test'),
          );
          await openSettings(tester, const Size(430, 952), 1);
          final field = find.byKey(const ValueKey('zlibrary-site'));
          expect(
            tester.widget<TextFormField>(field).controller!.text,
            'https://example.test',
          );
          await tester.runAsync(box.close);
          final action = find.text(
            remove ? 'Remover endere\u00e7o' : 'Salvar endere\u00e7o',
          );
          await tester.ensureVisible(action);
          await tester.tap(action);
          await tester.pumpAndSettle();
          expect(
            find.textContaining('Verifique o armazenamento'),
            findsOneWidget,
          );
          expect(find.textContaining('HiveError'), findsNothing);
          expect(
            tester.widget<TextFormField>(field).controller!.text,
            'https://example.test',
          );
          expect(catalog.searches, 1);
          expect(catalog.downloads, 0);
          expect(library.books, isEmpty);
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('discover-cover-another-source:book')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  });
}
