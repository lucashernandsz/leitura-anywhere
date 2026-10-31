import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:leitura_anywhere/app.dart';
import 'package:leitura_anywhere/data/book.dart';
import 'package:leitura_anywhere/data/catalog.dart';
import 'package:leitura_anywhere/data/catalog_settings.dart';
import 'package:leitura_anywhere/data/catalog_sources.dart';
import 'package:leitura_anywhere/data/library.dart';
import 'package:leitura_anywhere/data/zlibrary_catalog.dart';
import 'package:leitura_anywhere/ui/catalog_settings_screen.dart';
import 'package:leitura_anywhere/ui/discover.dart';

import 'support/epub_fixture.dart';

class _PrimaryCatalog implements BookCatalog {
  final book = Book(
    id: 'gutenberg:1',
    title: 'Livro Gutenberg',
    author: 'Autora',
    source: 'Project Gutenberg',
    downloadUrl: 'https://www.gutenberg.org/book.epub',
  );
  Completer<CatalogPage>? pending;
  int searches = 0;
  int downloads = 0;

  @override
  String get displayName => 'Project Gutenberg';
  @override
  String get usageNotice => 'Obras autorizadas.';
  @override
  Future<CatalogPage> search({
    String query = '',
    String? topic,
    int page = 1,
  }) async {
    searches++;
    return pending?.future ??
        CatalogPage(books: [book], hasNext: false, page: page);
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
  late Box<dynamic> settingsBox;
  late Library library;
  late CatalogSettings settings;
  late _PrimaryCatalog primary;
  late ZLibraryCatalog connector;
  late CatalogSources sources;
  late MockClient client;
  late List<http.Request> requests;
  Future<http.Response> Function(http.Request)? respond;

  http.Response jsonResponse(Object body, {int status = 200}) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  http.Response searchResponse({String title = 'Livro Z'}) => jsonResponse({
    'books': [
      {
        'id': 42,
        'hash': 'abc123',
        'title': title,
        'author': 'Autor',
        'extension': 'epub',
      },
    ],
    'hasNext': false,
  });

  setUp(() async {
    library = Library(
      await Hive.openBox<dynamic>('zlibrary-ui-books', bytes: Uint8List(0)),
    );
    await library.load();
    settingsBox = await Hive.openBox<dynamic>(
      'zlibrary-ui-settings',
      bytes: Uint8List(0),
    );
    settings = CatalogSettings(settingsBox);
    primary = _PrimaryCatalog();
    requests = [];
    respond = null;
    client = MockClient((request) async {
      requests.add(request);
      expect(request.method, 'POST');
      expect(request.url.origin, 'http://localhost:8787');
      expect(request.url.path, startsWith('/api/zlibrary/'));
      expect(request.headers['X-Leitura-Client'], '1');
      expect(request.headers['Content-Type'], startsWith('application/json'));
      expect(jsonDecode(request.body), isA<Map<String, dynamic>>());
      if (respond != null) return respond!(request);
      switch (request.url.pathSegments.last) {
        case 'login':
          return jsonResponse({'session': 'a' * 43});
        case 'logout':
          return jsonResponse({'success': true});
        case 'session':
          return connector.isAuthenticated
              ? jsonResponse({'session': 'a' * 43, 'expiresIn': 1800})
              : jsonResponse({'code': 'AUTH_REQUIRED'}, status: 401);
        case 'download':
          return http.Response.bytes(
            fixtureEpub(),
            200,
            headers: {'content-type': 'application/epub+zip'},
          );
        default:
          return searchResponse();
      }
    });
    connector = ZLibraryCatalog(
      client: client,
      endpoint: Uri.parse('http://localhost:8787/api/zlibrary/'),
    );
    sources = CatalogSources(primary: primary, zLibrary: connector);
  });

  tearDown(() async {
    sources.dispose();
    client.close();
    library.dispose();
    await Hive.close();
  });

  test(
    'restored sessions select Z-Library when the source was untouched',
    () async {
      respond = (_) async =>
          jsonResponse({'session': 'a' * 43, 'expiresIn': 30});
      await sources.restoreSession();
      expect(connector.isAuthenticated, isTrue);
      expect(sources.isZLibrary, isTrue);
    },
  );

  test('late restoration preserves an explicit Gutenberg selection', () async {
    final pending = Completer<http.Response>();
    respond = (_) => pending.future;
    final restoration = sources.restoreSession();
    sources.selectZLibrary(false);
    pending.complete(jsonResponse({'session': 'a' * 43, 'expiresIn': 30}));
    await restoration;
    expect(connector.isAuthenticated, isTrue);
    expect(sources.isZLibrary, isFalse);
  });

  test('failed restoration does not select Z-Library', () async {
    respond = (_) async => jsonResponse({'code': 'AUTH_REQUIRED'}, status: 401);
    await sources.restoreSession();
    expect(connector.isAuthenticated, isFalse);
    expect(sources.isZLibrary, isFalse);
  });

  testWidgets('each entry into Discover renews without replacing the source', (
    tester,
  ) async {
    respond = (_) async =>
        jsonResponse({'session': 'a' * 43, 'expiresIn': 1800});
    Widget screen(bool active) => MaterialApp(
      theme: leituraTheme,
      home: Scaffold(
        body: DiscoverScreen(
          active: active,
          library: library,
          catalog: sources,
          catalogSettings: settings,
          onOpen: (_) async {},
          onLibrary: () {},
        ),
      ),
    );
    await tester.pumpWidget(screen(false));
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    await tester.pumpWidget(screen(true));
    await tester.pumpAndSettle();
    expect(requests.length, 1);
    expect(connector.isAuthenticated, isTrue);
    expect(sources.isZLibrary, isFalse);
    await tester.pumpWidget(screen(true));
    await tester.pumpAndSettle();
    expect(requests.length, 1);
    await tester.pumpWidget(screen(false));
    await tester.pumpWidget(screen(true));
    await tester.pumpAndSettle();
    expect(requests.length, 2);
    expect(requests.every((r) => r.url.path.endsWith('/session')), isTrue);
    expect(sources.isZLibrary, isFalse);
    await connector.logout();
    requests.clear();
    await tester.pumpWidget(screen(false));
    await tester.pumpWidget(screen(true));
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(connector.isAuthenticated, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  Finder keyed(String key) => find.byKey(ValueKey(key));

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(430, 952),
    double scale = 1,
    bool settingsOnly = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MaterialApp(
        theme: leituraTheme,
        home: settingsOnly
            ? CatalogSettingsScreen(
                settings: settings,
                activeCatalog: primary.displayName,
                sources: sources,
              )
            : Scaffold(
                body: DiscoverScreen(
                  library: library,
                  catalog: sources,
                  catalogSettings: settings,
                  onOpen: (_) async {},
                  onLibrary: () {},
                ),
              ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openSettings(WidgetTester tester) =>
      tapVisible(tester, find.byTooltip('Fontes e contas'));

  Future<void> selectZLibrary(WidgetTester tester) async {
    await openSettings(tester);
    await tapVisible(tester, keyed('catalog-zlibrary'));
    expect(sources.isZLibrary, isTrue);
    await tester.pageBack();
    await tester.pumpAndSettle();
  }

  Future<void> search(WidgetTester tester, [String query = 'Livro']) async {
    await tester.enterText(find.byType(TextField).first, query);
    tester.testTextInput.hide();
    await tester.pump(const Duration(milliseconds: 501));
    await tester.pumpAndSettle();
  }

  Future<void> credentials(WidgetTester tester) async {
    await tester.ensureVisible(keyed('zlibrary-email'));
    await tester.enterText(keyed('zlibrary-email'), 'reader@example.test');
    await tester.ensureVisible(keyed('zlibrary-password'));
    await tester.enterText(keyed('zlibrary-password'), 'private-password');
    tester.testTextInput.hide();
  }

  testWidgets(
    'selects and searches without login, keeps heading and hides topics',
    (tester) async {
      await mount(tester);
      final heading = tester.getRect(keyed('discover-heading'));
      expect(keyed('discover-categories'), findsOneWidget);
      await selectZLibrary(tester);
      expect(tester.getRect(keyed('discover-heading')), heading);
      expect(
        find.text('Busque um t\u00edtulo ou autor no Z-Library.'),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(keyed('discover-categories'), findsNothing);
      expect(requests.single.url.path, '/api/zlibrary/session');
      requests.clear();
      expect(connector.isAuthenticated, isFalse);
      await search(tester);
      expect(keyed('discover-cover-zlibrary:42:abc123'), findsOneWidget);
      expect(requests.single.url.path, '/api/zlibrary/search');
      expect(jsonDecode(requests.single.body), {'query': 'Livro', 'page': 1});
      expect(requests.single.headers.containsKey('Authorization'), isFalse);
      await tapVisible(tester, keyed('discover-cover-zlibrary:42:abc123'));
      expect(find.text('Conectar conta para baixar'), findsOneWidget);
      await tapVisible(tester, find.text('Conectar conta para baixar'));
      expect(find.byType(CatalogSettingsScreen), findsOneWidget);
      expect(find.text('Baixar para a biblioteca'), findsNothing);
      expect(requests.length, 1);
      expect(library.books, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'login uses a separate form and clears password before awaiting',
    (tester) async {
      final login = Completer<http.Response>();
      respond = (_) => login.future;
      await mount(tester, settingsOnly: true);
      expect(find.byType(AutofillGroup), findsNothing);
      final field = tester.widget<TextFormField>(keyed('zlibrary-password'));
      final editable = tester.widget<TextField>(
        find.descendant(
          of: keyed('zlibrary-password'),
          matching: find.byType(TextField),
        ),
      );
      expect(editable.obscureText, isTrue);
      expect(editable.autocorrect, isFalse);
      expect(editable.enableSuggestions, isFalse);
      expect(editable.enableIMEPersonalizedLearning, isFalse);
      expect(editable.autofocus, isFalse);
      expect(editable.autofillHints, isNull);
      await credentials(tester);
      await tester.ensureVisible(find.text('Conectar conta'));
      await tester.tap(find.text('Conectar conta'));
      expect(field.controller!.text, isEmpty);
      await tester.pump();
      expect(find.text('Conectando...'), findsOneWidget);
      expect(tester.widget<ListTile>(keyed('catalog-primary')).onTap, isNull);
      expect(tester.widget<ListTile>(keyed('catalog-zlibrary')).onTap, isNull);
      expect(
        tester.widget<TextFormField>(keyed('zlibrary-site')).enabled,
        isFalse,
      );
      expect(jsonDecode(requests.single.body), {
        'email': 'reader@example.test',
        'password': 'private-password',
      });
      // The blank, independently validated site form must not block login.
      expect(settings.zLibrarySite, isNull);
      login.complete(jsonResponse({'session': 'a' * 43}));
      await tester.pumpAndSettle();
      expect(connector.isAuthenticated, isTrue);
      expect(find.text('Conta conectada'), findsOneWidget);
      expect(sources.isZLibrary, isFalse);
      expect(settingsBox.isEmpty, isTrue);
      expect(find.textContaining('private-password'), findsNothing);
      expect(find.textContaining('reader@example.test'), findsNothing);
      expect(tester.takeException(), isNull);
      connector.dispose();
    },
  );

  testWidgets('logout stays busy until bridge replies and clears both fields', (
    tester,
  ) async {
    await mount(tester, settingsOnly: true);
    await credentials(tester);
    await tapVisible(tester, find.text('Conectar conta'));
    final logout = Completer<http.Response>();
    respond = (_) => logout.future;
    await tester.ensureVisible(find.text('Sair da conta'));
    await tester.tap(find.text('Sair da conta'));
    await tester.pump();
    expect(connector.isAuthenticated, isFalse);
    expect(find.text('Saindo...'), findsOneWidget);
    expect(tester.widget<ListTile>(keyed('catalog-primary')).onTap, isNull);
    expect(tester.widget<ListTile>(keyed('catalog-zlibrary')).onTap, isNull);
    expect(
      tester.widget<TextFormField>(keyed('zlibrary-email')).enabled,
      isFalse,
    );
    expect(
      tester.widget<TextFormField>(keyed('zlibrary-password')).enabled,
      isFalse,
    );
    expect(
      tester.widget<TextFormField>(keyed('zlibrary-email')).controller!.text,
      isEmpty,
    );
    expect(
      tester.widget<TextFormField>(keyed('zlibrary-password')).controller!.text,
      isEmpty,
    );
    logout.complete(jsonResponse({'success': true}));
    await tester.pumpAndSettle();
    expect(find.text('Conectar conta'), findsOneWidget);
    expect(
      find.textContaining('Sua biblioteca foi preservada'),
      findsOneWidget,
    );
    expect(settingsBox.isEmpty, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    '30 minute expiry updates open settings without automatic login',
    (tester) async {
      await mount(tester, settingsOnly: true);
      await credentials(tester);
      await tapVisible(tester, find.text('Conectar conta'));
      expect(connector.isAuthenticated, isTrue);
      await tester.pump(const Duration(minutes: 30));
      await tester.pumpAndSettle();
      expect(connector.isAuthenticated, isFalse);
      expect(find.text('Conta n\u00e3o conectada'), findsOneWidget);
      expect(find.text('Sair da conta'), findsNothing);
      expect(find.text('Conta conectada para esta sess\u00e3o.'), findsNothing);
      expect(
        tester
            .widget<TextFormField>(keyed('zlibrary-password'))
            .controller!
            .text,
        isEmpty,
      );
      expect(requests.length, 1);
      expect(settingsBox.isEmpty, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('open book panel reacts to session expiry before download', (
    tester,
  ) async {
    await mount(tester);
    await selectZLibrary(tester);
    await search(tester);
    await openSettings(tester);
    await credentials(tester);
    await tapVisible(tester, find.text('Conectar conta'));
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tapVisible(tester, keyed('discover-cover-zlibrary:42:abc123'));
    expect(find.text('Baixar para a biblioteca'), findsOneWidget);
    await tester.pump(const Duration(minutes: 30));
    await tester.pumpAndSettle();
    expect(find.text('Baixar para a biblioteca'), findsNothing);
    expect(find.text('Conectar conta para baixar'), findsOneWidget);
    await tapVisible(tester, find.text('Conectar conta para baixar'));
    expect(find.byType(CatalogSettingsScreen), findsOneWidget);
    expect(requests.where((r) => r.url.path.endsWith('/download')), isEmpty);
    expect(library.books, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('validation and failed login never echo server secrets', (
    tester,
  ) async {
    respond = (_) async => jsonResponse({
      'message': 'reader@example.test private-password raw-token',
    }, status: 401);
    await mount(tester, settingsOnly: true);
    await tapVisible(tester, find.text('Conectar conta'));
    expect(find.text('Informe um email v\u00e1lido.'), findsOneWidget);
    expect(find.text('Informe a senha.'), findsOneWidget);
    expect(requests, isEmpty);
    await tester.enterText(keyed('zlibrary-email'), 'invalid-email');
    await tapVisible(tester, find.text('Conectar conta'));
    expect(requests, isEmpty);
    await credentials(tester);
    await tapVisible(tester, find.text('Conectar conta'));
    expect(connector.isAuthenticated, isFalse);
    expect(
      tester.widget<TextFormField>(keyed('zlibrary-password')).controller!.text,
      isEmpty,
    );
    expect(
      find.textContaining('N\u00e3o foi poss\u00edvel concluir'),
      findsOneWidget,
    );
    for (final secret in ['private-password', 'raw-token']) {
      expect(find.textContaining(secret), findsNothing);
    }
    expect(settingsBox.isEmpty, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'download imports EPUB; logout and primary selection preserve library',
    (tester) async {
      await tester.runAsync(() => library.add(primary.book, fixtureEpub()));
      await mount(tester);
      await selectZLibrary(tester);
      await search(tester);
      await openSettings(tester);
      await credentials(tester);
      await tapVisible(tester, find.text('Conectar conta'));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Fonte: Z-Library. Conta conectada.'), findsOneWidget);
      await tapVisible(tester, keyed('discover-cover-zlibrary:42:abc123'));
      await tester.tap(find.text('Baixar para a biblioteca'));
      for (var i = 0; i < 40 && library.books.length < 2; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      final download = requests.singleWhere(
        (r) => r.url.path.endsWith('/download'),
      );
      expect(download.headers['Authorization'], 'Bearer ${'a' * 43}');
      expect(jsonDecode(download.body), {'id': 42, 'hash': 'abc123'});
      expect(
        library.books.map((b) => b.book.id),
        containsAll([primary.book.id, 'zlibrary:42:abc123']),
      );
      expect(library.find('zlibrary:42:abc123')!.book.source, 'Z-Library');
      expect(primary.downloads, 0);
      await openSettings(tester);
      await tapVisible(tester, find.text('Sair da conta'));
      expect(connector.isAuthenticated, isFalse);
      expect(find.text('Conta n\u00e3o conectada'), findsOneWidget);
      expect(
        tester.widget<TextFormField>(keyed('zlibrary-email')).controller!.text,
        isEmpty,
      );
      expect(
        tester
            .widget<TextFormField>(keyed('zlibrary-password'))
            .controller!
            .text,
        isEmpty,
      );
      expect(requests.where((r) => r.url.path.endsWith('/logout')).length, 1);
      await tapVisible(tester, keyed('catalog-primary'));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(sources.isZLibrary, isFalse);
      expect(keyed('discover-categories'), findsOneWidget);
      expect(keyed('discover-cover-gutenberg:1'), findsOneWidget);
      expect(library.books.length, 2);
      expect(settingsBox.isEmpty, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('settings disabled during download; provider captured at start', (
    tester,
  ) async {
    await tester.runAsync(
      () => connector.login('reader@example.test', 'private-password'),
    );
    sources.selectZLibrary(true);
    await mount(tester);
    await search(tester);
    final download = Completer<http.Response>();
    respond = (_) => download.future;
    await tapVisible(tester, keyed('discover-cover-zlibrary:42:abc123'));
    await tester.tap(find.text('Baixar para a biblioteca'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.manage_accounts_outlined),
          )
          .onPressed,
      isNull,
    );
    // Even a programmatic source change cannot redirect an ongoing download.
    sources.selectZLibrary(false);
    await tester.pump();
    download.complete(
      http.Response.bytes(
        fixtureEpub(),
        200,
        headers: {'content-type': 'application/epub+zip'},
      ),
    );
    for (var i = 0; i < 40 && library.books.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(library.books.single.book.id, 'zlibrary:42:abc123');
    expect(primary.downloads, 0);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.manage_accounts_outlined),
          )
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
    connector.dispose();
  });

  for (final size in [
    const Size(320, 568),
    const Size(430, 952),
    const Size(1280, 800),
  ]) {
    testWidgets('connector forms and discovery fit $size at 200 percent', (
      tester,
    ) async {
      await mount(tester, size: size, scale: 2);
      await openSettings(tester);
      expect(find.text('Integra\u00e7\u00e3o pendente'), findsNothing);
      expect(find.textContaining('API n\u00e3o oficial'), findsOneWidget);
      expect(find.textContaining('apenas obras autorizadas'), findsOneWidget);
      expect(
        find.text(
          'Conta lembrada neste navegador por 30 dias, renovados ao abrir o app ou entrar em Descobrir. A senha n\u00e3o \u00e9 salva.',
        ),
        findsOneWidget,
      );
      await tapVisible(tester, keyed('catalog-zlibrary'));
      await credentials(tester);
      await tapVisible(tester, find.text('Conectar conta'));
      expect(connector.isAuthenticated, isTrue);
      expect(tester.takeException(), isNull);
      await tapVisible(tester, find.text('Sair da conta'));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        find.text('Busque um t\u00edtulo ou autor no Z-Library.'),
        findsOneWidget,
      );
      await search(tester);
      expect(keyed('discover-cover-zlibrary:42:abc123'), findsOneWidget);
      await tapVisible(tester, keyed('discover-cover-zlibrary:42:abc123'));
      await tapVisible(tester, find.text('Conectar conta para baixar'));
      expect(find.byType(CatalogSettingsScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'native connector has no credential form or selectable Z-Library',
    (tester) async {
      sources.dispose();
      primary = _PrimaryCatalog();
      connector = ZLibraryCatalog(client: client);
      sources = CatalogSources(primary: primary, zLibrary: connector);
      await mount(tester, settingsOnly: true);
      expect(
        find.text('Dispon\u00edvel na vers\u00e3o web pelo servidor local'),
        findsOneWidget,
      );
      expect(keyed('zlibrary-email'), findsNothing);
      expect(keyed('zlibrary-password'), findsNothing);
      expect(tester.widget<ListTile>(keyed('catalog-zlibrary')).onTap, isNull);
      expect(keyed('zlibrary-site'), findsOneWidget);
      expect(sources.isZLibrary, isFalse);
      expect(requests, isEmpty);
    },
  );

  testWidgets(
    'unapproved saved host blocks login and selection until removed',
    (tester) async {
      await tester.runAsync(
        () => settings.saveZLibrarySite('https://example.test'),
      );
      await mount(tester, settingsOnly: true);
      expect(
        find.textContaining('s\u00f3 suporta o dom\u00ednio aprovado'),
        findsOneWidget,
      );
      expect(tester.widget<ListTile>(keyed('catalog-zlibrary')).onTap, isNull);
      expect(
        tester.widget<TextFormField>(keyed('zlibrary-email')).enabled,
        isFalse,
      );
      expect(
        tester.widget<TextFormField>(keyed('zlibrary-password')).enabled,
        isFalse,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Conectar conta'),
            )
            .onPressed,
        isNull,
      );
      await tapVisible(tester, find.text('Remover endere\u00e7o'));
      expect(settings.zLibrarySite, isNull);
      expect(
        tester.widget<ListTile>(keyed('catalog-zlibrary')).onTap,
        isNotNull,
      );
      expect(requests, isEmpty);
      await credentials(tester);
      await tapVisible(tester, find.text('Conectar conta'));
      expect(
        requests.single.url,
        Uri.parse('http://localhost:8787/api/zlibrary/login'),
      );
      expect(settingsBox.isEmpty, isTrue);
      connector.dispose();
    },
  );

  testWidgets('saving generic or approved address never starts any operation', (
    tester,
  ) async {
    await mount(tester, settingsOnly: true);
    for (final host in ['example.test', 'z-library.biz']) {
      await tester.ensureVisible(keyed('zlibrary-site'));
      await tester.enterText(keyed('zlibrary-site'), 'https://$host');
      tester.testTextInput.hide();
      await tapVisible(tester, find.text('Salvar endere\u00e7o'));
      expect(settings.zLibrarySite, Uri.parse('https://$host'));
      expect(requests, isEmpty);
      expect(primary.searches, 0);
      expect(primary.downloads, 0);
      expect(sources.isZLibrary, isFalse);
      expect(connector.isAuthenticated, isFalse);
      expect(library.books, isEmpty);
      expect(settingsBox.toMap(), {'zLibrarySite': 'https://$host'});
    }
    expect(tester.widget<ListTile>(keyed('catalog-zlibrary')).onTap, isNotNull);
  });

  testWidgets(
    'old Z-Library response cannot replace results after source change',
    (tester) async {
      final pending = Completer<http.Response>();
      respond = (request) async => request.url.path.endsWith('/session')
          ? jsonResponse({'code': 'AUTH_REQUIRED'}, status: 401)
          : pending.future;
      sources.selectZLibrary(true);
      await mount(tester);
      await tester.enterText(find.byType(TextField), 'old query');
      await tester.pump(const Duration(milliseconds: 501));
      await tester.pump();
      expect(requests.where((r) => r.url.path.endsWith('/search')).length, 1);
      sources.selectZLibrary(false);
      await tester.pumpAndSettle();
      expect(keyed('discover-cover-gutenberg:1'), findsOneWidget);
      pending.complete(searchResponse(title: 'Obsolete Z-Library'));
      await tester.pumpAndSettle();
      expect(keyed('discover-cover-gutenberg:1'), findsOneWidget);
      expect(keyed('discover-cover-zlibrary:42:abc123'), findsNothing);
      expect(find.textContaining('Obsolete Z-Library'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('old primary response cannot replace Z-Library results', (
    tester,
  ) async {
    final pending = Completer<CatalogPage>();
    primary.pending = pending;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DiscoverScreen(
            library: library,
            catalog: sources,
            catalogSettings: settings,
            onOpen: (_) async {},
            onLibrary: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    sources.selectZLibrary(true);
    await tester.pumpAndSettle();
    await search(tester);
    expect(keyed('discover-cover-zlibrary:42:abc123'), findsOneWidget);
    pending.complete(
      CatalogPage(books: [primary.book], hasNext: true, page: 1),
    );
    await tester.pumpAndSettle();
    expect(keyed('discover-cover-zlibrary:42:abc123'), findsOneWidget);
    expect(keyed('discover-cover-gutenberg:1'), findsNothing);
    expect(find.text('Explorar mais livros'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('session notification invalidates pending search and reloads', (
    tester,
  ) async {
    sources.selectZLibrary(true);
    await mount(tester);
    final pending = Completer<http.Response>();
    respond = (request) async => request.url.path.endsWith('/login')
        ? jsonResponse({'session': 'a' * 43})
        : requests.where((r) => r.url.path.endsWith('/search')).length == 1
        ? pending.future
        : searchResponse(title: 'Current session');
    await tester.enterText(find.byType(TextField), 'Livro');
    await tester.pump(const Duration(milliseconds: 501));
    await tester.pump();
    await tester.runAsync(() async {
      await connector.login('reader@example.test', 'private-password');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(find.text('Current session'), findsWidgets);
    pending.complete(searchResponse(title: 'Previous session'));
    await tester.pumpAndSettle();
    expect(find.text('Current session'), findsWidgets);
    expect(find.text('Previous session'), findsNothing);
    expect(requests.where((r) => r.url.path.endsWith('/search')).length, 2);
    expect(tester.takeException(), isNull);
    connector.dispose();
  });

  testWidgets('listeners detach on catalog replacement and widget disposal', (
    tester,
  ) async {
    await mount(tester);
    final replacementPrimary = _PrimaryCatalog();
    final replacement = CatalogSources(
      primary: replacementPrimary,
      zLibrary: ZLibraryCatalog(
        client: client,
        endpoint: Uri.parse('http://localhost:8787/api/zlibrary/'),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: leituraTheme,
        home: Scaffold(
          body: DiscoverScreen(
            library: library,
            catalog: replacement,
            catalogSettings: settings,
            onOpen: (_) async {},
            onLibrary: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final count = replacementPrimary.searches;
    sources.selectZLibrary(true);
    await tester.pumpAndSettle();
    expect(replacementPrimary.searches, count);
    replacement.selectZLibrary(true);
    await tester.pumpAndSettle();
    expect(
      find.text('Busque um t\u00edtulo ou autor no Z-Library.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    replacement.selectZLibrary(false);
    sources.selectZLibrary(false);
    replacement.dispose();
    expect(tester.takeException(), isNull);
  });
}
