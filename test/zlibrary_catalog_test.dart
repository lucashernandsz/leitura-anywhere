import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:leitura_anywhere/data/book.dart';
import 'package:leitura_anywhere/data/catalog.dart';
import 'package:leitura_anywhere/data/catalog_settings.dart';
import 'package:leitura_anywhere/data/zlibrary_catalog.dart';

import 'support/epub_fixture.dart';

final endpoint = Uri.parse('http://localhost:8787/api/zlibrary/');
final session = List.filled(43, 'a').join();
final item = {
  'id': 42,
  'hash': 'abc123',
  'title': 'Livro Z',
  'author': 'Autor',
  'extension': 'epub',
};
final book = Book(
  id: 'zlibrary:42:abc123',
  title: 'Livro Z',
  author: 'Autor',
  source: 'Z-Library',
  downloadUrl: 'https://z-library.biz/eapi/book/42/abc123/file',
);

http.Response json(Object value, {int status = 200}) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

ZLibraryCatalog catalog(
  FutureOr<http.Response> Function(http.Request) handler, {
  Duration timeout = const Duration(seconds: 5),
  CatalogSettings? settings,
}) {
  final client = MockClient((request) async => handler(request));
  final result = ZLibraryCatalog(
    client: client,
    endpoint: endpoint,
    timeout: timeout,
    settings: settings,
  );
  addTearDown(() {
    result.dispose();
    client.close();
  });
  return result;
}

class _ControlledBox implements Box<dynamic> {
  final Box<dynamic> box;
  bool failWrites = false;
  bool failFlush = false;
  Future<void> Function(bool)? beforeWrite;

  _ControlledBox(this.box);

  @override
  bool get isOpen => box.isOpen;

  @override
  dynamic get(dynamic key, {dynamic defaultValue}) =>
      box.get(key, defaultValue: defaultValue);

  @override
  Future<void> put(dynamic key, dynamic value) async {
    if (failWrites) throw StateError('private storage detail');
    await beforeWrite?.call(value as bool);
    await box.put(key, value);
  }

  @override
  Future<void> flush() async {
    if (failFlush) throw StateError('private flush detail');
    await box.flush();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'default native catalog stays unsupported without affecting the library',
    () {
      final source = ZLibraryCatalog();
      addTearDown(source.dispose);
      expect(source.supported, isFalse);
      expect(source.isAuthenticated, isFalse);
    },
  );

  for (final value in [
    'https://localhost:8787/api/zlibrary/',
    'http://evil.test/api/zlibrary/',
    'http://localhost:8787/api/proxy/',
    'http://user:password@localhost:8787/api/zlibrary/',
    'http://localhost:8787/api/zlibrary/?token=secret',
    'http://localhost:8787/api/zlibrary/#secret',
  ]) {
    test(
      'rejects credential transport outside the fixed local bridge: $value',
      () {
        expect(
          () => ZLibraryCatalog(endpoint: Uri.parse(value)),
          throwsA(isA<ApiException>()),
        );
      },
    );
  }

  test(
    'empty search performs no requests and invalid page is rejected',
    () async {
      final source = catalog((_) => throw StateError('No HTTP expected'));
      expect((await source.search()).books, isEmpty);
      await expectLater(
        source.search(query: 'livro', page: 0),
        throwsArgumentError,
      );
    },
  );

  test(
    'public search sends no credentials and produces stable, non-secret metadata',
    () async {
      final source = catalog((request) {
        expect(request.url, endpoint.resolve('search'));
        expect(request.method, 'POST');
        expect(request.headers['X-Leitura-Client'], '1');
        expect(request.headers['Authorization'], isNull);
        expect(request.headers['Cookie'], isNull);
        expect(jsonDecode(request.body), {'query': 'Dom Casmurro', 'page': 2});
        return json({
          'books': [item],
          'hasNext': true,
        });
      });
      final page = await source.search(
        query: '  Dom Casmurro ',
        topic: 'ignored',
        page: 2,
      );
      expect(page.hasNext, isTrue);
      expect(page.page, 2);
      expect(page.books.single.id, 'zlibrary:42:abc123');
      expect(page.books.single.downloadable, isTrue);
      expect(page.books.single.coverUrl, isNull);
      expect(page.books.single.toJson().values, isNot(contains(session)));
    },
  );

  test(
    'login retains only an opaque session; downloads are bounded EPUB bytes',
    () async {
      final fixture = fixtureEpub();
      final progress = <double?>[];
      final source = catalog((request) {
        if (request.url.path.endsWith('/login')) {
          expect(request.headers['Authorization'], isNull);
          expect(jsonDecode(request.body), {
            'email': 'fixture@example.invalid',
            'password': 'fixture-password',
          });
          return json({'session': session});
        }
        expect(request.url, endpoint.resolve('download'));
        expect(request.headers['Authorization'], 'Bearer $session');
        expect(jsonDecode(request.body), {'id': 42, 'hash': 'abc123'});
        return http.Response.bytes(
          fixture,
          200,
          headers: {'content-type': 'application/epub+zip'},
        );
      });
      await source.login(' fixture@example.invalid ', 'fixture-password');
      expect(source.isAuthenticated, isTrue);
      expect(await source.download(book, onProgress: progress.add), fixture);
      expect(progress.last, 1);
    },
  );

  test(
    'public cover metadata survives serialization without a local endpoint',
    () async {
      const cover =
          'https://s3proxy-alp2-covers.cdn-zlib.sk/covers299/fiction/cover.jpg';
      final source = catalog(
        (_) => json({
          'books': [
            {...item, 'coverUrl': cover},
          ],
          'hasNext': false,
        }),
      );
      final result = (await source.search(query: 'livro')).books.single;
      expect(result.coverUrl, cover);
      expect(Book.fromJson(result.toJson()).coverUrl, cover);
      expect(result.toJson().toString(), isNot(contains('localhost')));
    },
  );

  test(
    'missing or unsafe cover metadata keeps the book and illustrated fallback',
    () async {
      const cover =
          'https://s3proxy-alp2-covers.cdn-zlib.sk/covers299/fiction/cover.jpg';
      for (final value in <Object?>[
        null,
        42,
        '',
        'https://evil.test/cover.jpg',
        cover.replaceFirst('https:', 'http:'),
        cover.replaceFirst('.sk/', '.sk:444/'),
        cover.replaceFirst('https://', 'https://user:password@'),
        cover.replaceFirst('https://', 'https://@'),
        cover.replaceFirst('.sk/', '.sk.evil.test/'),
        '$cover?token=secret',
        '$cover#fragment',
        '$cover\n',
        cover.replaceFirst('/covers299/', '/private/'),
        cover.replaceFirst('.jpg', '.svg'),
      ]) {
        final source = catalog(
          (_) => json({
            'books': [
              {...item, 'coverUrl': value},
            ],
            'hasNext': false,
          }),
        );
        final result = (await source.search(query: 'livro')).books.single;
        expect(result.id, book.id);
        expect(result.coverUrl, isNull, reason: '$value');
      }
    },
  );

  test(
    'download without a session or with forged identity performs no requests',
    () async {
      final source = catalog((_) => throw StateError('No HTTP expected'));
      await expectLater(source.download(book), throwsA(isA<ApiException>()));
      await expectLater(
        source.download(
          Book(
            id: book.id,
            title: book.title,
            author: book.author,
            source: book.source,
            downloadUrl: 'https://evil.test/secret',
          ),
        ),
        throwsA(isA<ApiException>()),
      );
    },
  );

  test(
    'server 401 clears only the active session and never displays remote secrets',
    () async {
      var notifications = 0;
      final source = catalog(
        (request) => request.url.path.endsWith('/login')
            ? json({'session': session})
            : json({
                'code': 'AUTH_REQUIRED',
                'error': 'password fixture-password userkey-secret',
              }, status: 401),
      );
      source.addListener(() => notifications++);
      await source.login('fixture@example.invalid', 'fixture-password');
      await expectLater(
        source.download(book),
        throwsA(
          isA<ApiException>().having(
            (error) => error.message,
            'safe message',
            allOf(
              contains('expirada'),
              isNot(contains('fixture-password')),
              isNot(contains('userkey')),
            ),
          ),
        ),
      );
      expect(source.isAuthenticated, isFalse);
      expect(notifications, 2);
    },
  );

  test('logout clears local access even if bridge fails', () async {
    final source = catalog(
      (request) => request.url.path.endsWith('/login')
          ? json({'session': session})
          : throw StateError('private-network-detail'),
    );
    await source.login('fixture@example.invalid', 'fixture-password');
    final future = source.logout();
    expect(source.isAuthenticated, isFalse);
    await future;
  });

  test(
    'HTTP 401 revokes local access even when its body is malformed',
    () async {
      final source = catalog(
        (request) => request.url.path.endsWith('/login')
            ? json({'session': session})
            : http.Response(
                'not-json-private-detail',
                401,
                headers: {'content-type': 'application/json'},
              ),
      );
      await source.login('fixture@example.invalid', 'fixture-password');
      await expectLater(source.download(book), throwsA(isA<ApiException>()));
      expect(source.isAuthenticated, isFalse);
    },
  );

  test('logout during login cannot resurrect a session', () async {
    final pending = Completer<http.Response>();
    var revoked = false;
    final source = catalog((request) {
      if (request.url.path.endsWith('/login')) return pending.future;
      expect(request.url, endpoint.resolve('logout'));
      expect(request.headers['Authorization'], 'Bearer $session');
      revoked = true;
      return json({'success': 1});
    });
    final login = source.login('fixture@example.invalid', 'fixture-password');
    await source.logout();
    pending.complete(json({'session': session}));
    await login;
    expect(source.isAuthenticated, isFalse);
    expect(revoked, isTrue);
  });

  test(
    'logout during download prevents returning bytes for library import',
    () async {
      final pending = Completer<http.Response>();
      final source = catalog((request) {
        if (request.url.path.endsWith('/login')) {
          return json({'session': session});
        }
        if (request.url.path.endsWith('/logout')) return json({'success': 1});
        return pending.future;
      });
      await source.login('fixture@example.invalid', 'fixture-password');
      final download = source.download(book);
      final rejected = expectLater(download, throwsA(isA<ApiException>()));
      await source.logout();
      pending.complete(
        http.Response.bytes(
          fixtureEpub(),
          200,
          headers: {'content-type': 'application/epub+zip'},
        ),
      );
      await rejected;
    },
  );

  testWidgets('session timer revokes access at 30 minutes', (tester) async {
    final source = catalog((_) => json({'session': session}));
    await source.login('fixture@example.invalid', 'fixture-password');
    await tester.pump(const Duration(minutes: 29));
    expect(source.isAuthenticated, isTrue);
    await tester.pump(const Duration(minutes: 1));
    expect(source.isAuthenticated, isFalse);
  });

  testWidgets('restores the local session for its remaining lifetime only', (
    tester,
  ) async {
    var calls = 0;
    final source = catalog((request) {
      calls++;
      expect(request.url, endpoint.resolve('session'));
      expect(request.headers['Authorization'], isNull);
      expect(jsonDecode(request.body), isEmpty);
      return json({'session': session, 'expiresIn': 15});
    });
    expect(await source.restoreSession(), isTrue);
    expect(source.isAuthenticated, isTrue);
    expect(await source.restoreSession(), isTrue);
    expect(calls, 1);
    await tester.pump(const Duration(seconds: 14));
    expect(source.isAuthenticated, isTrue);
    await tester.pump(const Duration(seconds: 1));
    expect(source.isAuthenticated, isFalse);
  });

  test(
    'unavailable bridge and invalid restored sessions never block startup',
    () async {
      for (final value in [
        {'session': session, 'expiresIn': 0},
        {'session': session, 'expiresIn': 1801},
        {'session': session, 'expiresIn': '1800'},
        {'session': session},
        {'session': 'remote-secret', 'expiresIn': 1800},
      ]) {
        final source = catalog((_) => json(value));
        expect(await source.restoreSession(), isFalse);
        expect(source.isAuthenticated, isFalse);
      }
      final offline = catalog((_) => throw StateError('offline'));
      expect(await offline.restoreSession(), isFalse);
      final expired = catalog(
        (_) => json({'code': 'AUTH_REQUIRED'}, status: 401),
      );
      expect(await expired.restoreSession(), isFalse);
      final native = ZLibraryCatalog();
      addTearDown(native.dispose);
      expect(await native.restoreSession(), isFalse);
    },
  );

  testWidgets(
    'explicit renewal extends access without duplicate notifications',
    (tester) async {
      var calls = 0;
      var changes = 0;
      final source = catalog((_) {
        calls++;
        return json({'session': session, 'expiresIn': 60});
      });
      source.addListener(() => changes++);
      expect(await source.restoreSession(), isTrue);
      await tester.pump(const Duration(seconds: 50));
      expect(await source.restoreSession(renew: true), isTrue);
      expect(calls, 2);
      expect(changes, 1);
      await tester.pump(const Duration(seconds: 11));
      expect(source.isAuthenticated, isTrue);
      await tester.pump(const Duration(seconds: 49));
      expect(source.isAuthenticated, isFalse);
    },
  );

  test('concurrent restorations share one request', () async {
    var calls = 0;
    final pending = Completer<http.Response>();
    final source = catalog((_) {
      calls++;
      return pending.future;
    });
    final first = source.restoreSession(renew: true);
    final second = source.restoreSession(renew: true);
    pending.complete(json({'session': session, 'expiresIn': 1800}));
    expect(await Future.wait([first, second]), [true, true]);
    expect(calls, 1);
  });

  testWidgets('renewal can finish after the previous access grant expires', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    var calls = 0;
    final source = catalog((_) {
      if (++calls == 1) return json({'session': session, 'expiresIn': 60});
      return pending.future;
    });
    expect(await source.restoreSession(), isTrue);
    await tester.pump(const Duration(seconds: 59));
    final renewal = source.restoreSession(renew: true);
    await tester.pump(const Duration(seconds: 1));
    expect(source.isAuthenticated, isFalse);
    final concurrent = source.restoreSession(renew: true);
    pending.complete(json({'session': session, 'expiresIn': 1800}));
    expect(await Future.wait([renewal, concurrent]), [true, true]);
    expect(calls, 2);
    expect(source.isAuthenticated, isTrue);
    source.dispose();
  });

  test(
    'offline renewal preserves access; 401 revokes it without a login',
    () async {
      var offline = false;
      var revoked = false;
      final source = catalog((request) {
        expect(request.url, endpoint.resolve('session'));
        if (offline) throw StateError('offline');
        if (revoked) return json({'code': 'AUTH_REQUIRED'}, status: 401);
        return json({'session': session, 'expiresIn': 1800});
      });
      expect(await source.restoreSession(), isTrue);
      offline = true;
      expect(await source.restoreSession(renew: true), isFalse);
      expect(source.isAuthenticated, isTrue);
      offline = false;
      revoked = true;
      expect(await source.restoreSession(renew: true), isFalse);
      expect(source.isAuthenticated, isFalse);
    },
  );

  testWidgets('logout retains the bearer needed to revoke expired access', (
    tester,
  ) async {
    var revoked = false;
    final source = catalog((request) {
      if (request.url.path.endsWith('/login')) {
        return json({'session': session});
      }
      expect(request.url, endpoint.resolve('logout'));
      expect(request.headers['Authorization'], 'Bearer $session');
      revoked = true;
      return json({'success': 1});
    });
    await source.login('fixture@example.invalid', 'fixture-password');
    await tester.pump(const Duration(minutes: 30));
    expect(source.isAuthenticated, isFalse);
    await source.logout();
    expect(revoked, isTrue);
    expect(await source.restoreSession(renew: true), isFalse);
  });

  testWidgets('an expired access grant renews before download', (tester) async {
    final operations = <String>[];
    final source = catalog((request) {
      final operation = request.url.pathSegments.last;
      operations.add(operation);
      if (operation == 'login') return json({'session': session});
      if (operation == 'session') {
        return json({'session': session, 'expiresIn': 1800});
      }
      return http.Response.bytes(
        fixtureEpub(),
        200,
        headers: {'content-type': 'application/epub+zip'},
      );
    });
    await source.login('fixture@example.invalid', 'fixture-password');
    await tester.pump(const Duration(minutes: 30));
    expect(await source.download(book), isNotEmpty);
    expect(operations, ['login', 'session', 'download']);
    source.dispose();
  });

  test('logout wins over a renewal of an authenticated session', () async {
    final pending = Completer<http.Response>();
    final source = catalog((request) {
      if (request.url.path.endsWith('/session')) return pending.future;
      return json({'session': session});
    });
    await source.login('fixture@example.invalid', 'fixture-password');
    final renewal = source.restoreSession(renew: true);
    await source.logout();
    pending.complete(json({'session': session, 'expiresIn': 1800}));
    expect(await renewal, isFalse);
    expect(source.isAuthenticated, isFalse);
    expect(await source.restoreSession(renew: true), isFalse);
  });

  testWidgets('download 401 after expiry invalidates a late renewal', (
    tester,
  ) async {
    final file = Completer<http.Response>();
    final refresh = Completer<http.Response>();
    final source = catalog((request) {
      if (request.url.path.endsWith('/login')) {
        return json({'session': session});
      }
      return request.url.path.endsWith('/session')
          ? refresh.future
          : file.future;
    });
    await source.login('fixture@example.invalid', 'fixture-password');
    await tester.pump(const Duration(minutes: 29, seconds: 59));
    final download = source.download(book);
    final rejected = expectLater(download, throwsA(isA<ApiException>()));
    final renewal = source.restoreSession(renew: true);
    await tester.pump(const Duration(seconds: 1));
    file.complete(json({'code': 'AUTH_REQUIRED'}, status: 401));
    await rejected;
    refresh.complete(json({'session': session, 'expiresIn': 1800}));
    expect(await renewal, isFalse);
    expect(source.isAuthenticated, isFalse);
    source.dispose();
  });

  test(
    'logout or disposal during restoration cannot resurrect account access',
    () async {
      for (final dispose in [false, true]) {
        final pending = Completer<http.Response>();
        final source = catalog((_) => pending.future);
        final restore = source.restoreSession();
        if (dispose) {
          source.dispose();
        } else {
          await source.logout();
        }
        pending.complete(json({'session': session, 'expiresIn': 1800}));
        expect(await restore, isFalse);
        expect(source.isAuthenticated, isFalse);
      }
    },
  );

  test('an older restoration cannot replace a new login', () async {
    final pending = Completer<http.Response>();
    final source = catalog(
      (request) => request.url.path.endsWith('/session')
          ? pending.future
          : json({'session': session}),
    );
    final restore = source.restoreSession();
    await source.login('fixture@example.invalid', 'fixture-password');
    pending.complete(
      json({'session': List.filled(43, 'b').join(), 'expiresIn': 1800}),
    );
    expect(await restore, isFalse);
    expect(source.isAuthenticated, isTrue);
  });

  group('persistent logout intent', () {
    const restoreKey = 'zLibrarySessionRestorationAllowed';
    late Directory directory;
    late Box<dynamic> box;
    late _ControlledBox controlled;
    late CatalogSettings settings;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('zlibrary-session-');
      Hive.init(directory.path);
      box = await Hive.openBox<dynamic>('settings');
      controlled = _ControlledBox(box);
      settings = CatalogSettings(controlled);
    });

    tearDown(() async {
      await Hive.close();
      await directory.delete(recursive: true);
    });

    test(
      'missing or unavailable settings deny restoration without HTTP',
      () async {
        for (final storage in [
          settings,
          CatalogSettings.lazy(() async => throw StateError('offline storage')),
        ]) {
          final source = catalog(
            (_) => throw StateError('No HTTP expected'),
            settings: storage,
          );
          expect(await source.restoreSession(), isFalse);
          expect(source.isAuthenticated, isFalse);
        }
      },
    );

    test(
      'failed remote logout cannot restore in a new instance after reopen',
      () async {
        final source = catalog(
          (request) => request.url.path.endsWith('/login')
              ? json({'session': session})
              : throw StateError('bridge offline'),
          settings: settings,
        );
        await source.login('fixture@example.invalid', 'fixture-password');
        expect(box.toMap(), {restoreKey: true});
        await source.logout();
        expect(source.isAuthenticated, isFalse);
        source.dispose();
        await box.close();
        box = await Hive.openBox<dynamic>('settings');
        expect(box.toMap(), {restoreKey: false});
        final reopened = catalog(
          (_) => throw StateError('No HTTP expected'),
          settings: CatalogSettings(box),
        );
        expect(await reopened.restoreSession(), isFalse);
      },
    );

    test('a new explicit login re-enables restoration after reopen', () async {
      await settings.setZLibrarySessionRestoration(false);
      final source = catalog(
        (_) => json({'session': session}),
        settings: settings,
      );
      await source.login('fixture@example.invalid', 'fixture-password');
      source.dispose();
      await box.close();
      box = await Hive.openBox<dynamic>('settings');
      final reopened = catalog((request) {
        expect(request.url.path, endsWith('/session'));
        return json({'session': session, 'expiresIn': 60});
      }, settings: CatalogSettings(box));
      expect(await reopened.restoreSession(), isTrue);
      expect(box.toMap(), {restoreKey: true});
    });

    for (final failure in ['put', 'flush']) {
      test(
        'failed logout $failure reports failure and permits a safe retry',
        () async {
          final source = catalog(
            (request) => request.url.path.endsWith('/login')
                ? json({'session': session})
                : throw StateError('bridge offline'),
            settings: settings,
          );
          await source.login('fixture@example.invalid', 'fixture-password');
          controlled.failWrites = failure == 'put';
          controlled.failFlush = failure == 'flush';
          await expectLater(
            source.logout(),
            throwsA(
              isA<ApiException>().having(
                (error) => error.message,
                'retryable storage error',
                allOf(
                  contains('Tente sair novamente'),
                  isNot(contains('private')),
                ),
              ),
            ),
          );
          expect(source.isAuthenticated, isTrue);
          expect(await source.restoreSession(), isFalse);
          expect(await settings.canRestoreZLibrarySession(), isFalse);
          await expectLater(
            source.download(book),
            throwsA(isA<ApiException>()),
          );
          expect(box.get(restoreKey), failure == 'put');
          controlled.failWrites = false;
          controlled.failFlush = false;
          await source.logout();
          expect(source.isAuthenticated, isFalse);
          expect(box.get(restoreKey), isFalse);
        },
      );
    }

    test(
      'failed login persistence never enables restoration or local access',
      () async {
        var revoked = 0;
        final source = catalog((request) {
          if (request.url.path.endsWith('/login')) {
            return json({'session': session});
          }
          expect(request.url.path, endsWith('/logout'));
          revoked++;
          return json({'success': 1});
        }, settings: settings);
        controlled.failWrites = true;
        await expectLater(
          source.login('fixture@example.invalid', 'fixture-password'),
          throwsA(isA<ApiException>()),
        );
        expect(source.isAuthenticated, isFalse);
        expect(await source.restoreSession(), isFalse);
        expect(revoked, 1);
        controlled.failWrites = false;
        await source.login('fixture@example.invalid', 'fixture-password');
        expect(source.isAuthenticated, isTrue);
        expect(await settings.canRestoreZLibrarySession(), isTrue);
      },
    );

    test(
      'logout invalidates restoration while lazy storage is loading',
      () async {
        await settings.setZLibrarySessionRestoration(true);
        final opened = Completer<Box<dynamic>>();
        final lazy = CatalogSettings.lazy(() => opened.future);
        final source = catalog(
          (_) => throw StateError('No HTTP expected'),
          settings: lazy,
        );
        final restore = source.restoreSession();
        final logout = source.logout();
        opened.complete(box);
        expect(await restore, isFalse);
        await logout;
        expect(box.get(restoreKey), isFalse);
      },
    );

    test(
      'logout rejects a late restore while its persistence is pending',
      () async {
        await settings.setZLibrarySessionRestoration(true);
        final response = Completer<http.Response>();
        final requested = Completer<void>();
        final writing = Completer<void>();
        final release = Completer<void>();
        controlled.beforeWrite = (allowed) async {
          expect(allowed, isFalse);
          writing.complete();
          await release.future;
        };
        final source = catalog((request) {
          expect(request.url.path, endsWith('/session'));
          requested.complete();
          return response.future;
        }, settings: settings);
        final restore = source.restoreSession();
        await requested.future;
        final logout = source.logout();
        await writing.future;
        response.complete(json({'session': session, 'expiresIn': 1800}));
        expect(await restore, isFalse);
        expect(await source.restoreSession(), isFalse);
        release.complete();
        await logout;
        expect(source.isAuthenticated, isFalse);
        expect(box.get(restoreKey), isFalse);
      },
    );

    test(
      'logout during remote login cannot re-enable persisted restoration',
      () async {
        final response = Completer<http.Response>();
        final source = catalog(
          (request) => request.url.path.endsWith('/login')
              ? response.future
              : json({'success': 1}),
          settings: settings,
        );
        final login = source.login(
          'fixture@example.invalid',
          'fixture-password',
        );
        await source.logout();
        response.complete(json({'session': session}));
        await login;
        expect(source.isAuthenticated, isFalse);
        expect(box.get(restoreKey), isFalse);
      },
    );

    test('logout wins over a login awaiting permission persistence', () async {
      final writing = Completer<void>();
      final release = Completer<void>();
      controlled.beforeWrite = (allowed) async {
        if (allowed) {
          writing.complete();
          await release.future;
        }
      };
      final source = catalog(
        (request) => request.url.path.endsWith('/login')
            ? json({'session': session})
            : json({'success': 1}),
        settings: settings,
      );
      final login = source.login('fixture@example.invalid', 'fixture-password');
      await writing.future;
      expect(await source.restoreSession(), isFalse);
      final logout = source.logout();
      release.complete();
      await Future.wait([login, logout]);
      expect(source.isAuthenticated, isFalse);
      expect(await CatalogSettings(box).canRestoreZLibrarySession(), isFalse);
    });

    test('a newer login wins over logout awaiting persistence', () async {
      final writing = Completer<void>();
      final release = Completer<void>();
      controlled.beforeWrite = (allowed) async {
        if (!allowed) {
          writing.complete();
          await release.future;
        }
      };
      final source = catalog(
        (_) => json({'session': session}),
        settings: settings,
      );
      final logout = source.logout();
      await writing.future;
      final login = source.login('fixture@example.invalid', 'fixture-password');
      release.complete();
      await Future.wait([logout, login]);
      expect(source.isAuthenticated, isTrue);
      expect(await CatalogSettings(box).canRestoreZLibrarySession(), isTrue);
    });

    test(
      'pending logout blocks downloads before its write completes',
      () async {
        final writing = Completer<void>();
        final release = Completer<void>();
        final source = catalog(
          (_) => json({'session': session}),
          settings: settings,
        );
        await source.login('fixture@example.invalid', 'fixture-password');
        controlled.beforeWrite = (_) async {
          writing.complete();
          await release.future;
        };
        final logout = source.logout();
        await writing.future;
        expect(source.isAuthenticated, isTrue);
        expect(box.get(restoreKey), isTrue);
        await expectLater(source.download(book), throwsA(isA<ApiException>()));
        expect(await source.restoreSession(), isFalse);
        release.complete();
        await logout;
        expect(source.isAuthenticated, isFalse);
        expect(box.get(restoreKey), isFalse);
      },
    );

    test('pending logout rejects bytes from an in-flight download', () async {
      final response = Completer<http.Response>();
      final downloading = Completer<void>();
      final writing = Completer<void>();
      final release = Completer<void>();
      final source = catalog((request) {
        if (request.url.path.endsWith('/login')) {
          return json({'session': session});
        }
        if (request.url.path.endsWith('/logout')) return json({'success': 1});
        downloading.complete();
        return response.future;
      }, settings: settings);
      await source.login('fixture@example.invalid', 'fixture-password');
      final download = source.download(book);
      final rejected = expectLater(download, throwsA(isA<ApiException>()));
      await downloading.future;
      controlled.beforeWrite = (_) async {
        writing.complete();
        await release.future;
      };
      final logout = source.logout();
      await writing.future;
      response.complete(
        http.Response.bytes(
          fixtureEpub(),
          200,
          headers: {'content-type': 'application/epub+zip'},
        ),
      );
      await rejected;
      release.complete();
      await logout;
      expect(source.isAuthenticated, isFalse);
    });
  });

  test(
    'without settings logout still blocks restoration in the same instance',
    () async {
      final source = catalog(
        (request) => request.url.path.endsWith('/login')
            ? json({'session': session})
            : throw StateError('bridge offline'),
      );
      await source.login('fixture@example.invalid', 'fixture-password');
      await source.logout();
      expect(await source.restoreSession(), isFalse);
    },
  );

  for (final response in [
    http.Response(
      '<html>private-secret</html>',
      200,
      headers: {'content-type': 'text/html'},
    ),
    json({'session': 'remote-secret'}),
    json({'code': 'unexpected', 'error': 'private-secret'}, status: 502),
    http.Response('', 302, headers: {'location': 'https://evil.test/'}),
  ]) {
    test(
      'login rejects malformed responses without exposing payloads: ${response.statusCode}/${response.headers['content-type']}',
      () async {
        final source = catalog((_) => response);
        await expectLater(
          source.login('fixture@example.invalid', 'fixture-password'),
          throwsA(
            isA<ApiException>().having(
              (error) => error.message,
              'sanitized',
              allOf(
                isNot(contains('private-secret')),
                isNot(contains('remote-secret')),
              ),
            ),
          ),
        );
        expect(source.isAuthenticated, isFalse);
      },
    );
  }

  test('non-EPUB metadata and invalid ZIP are rejected', () async {
    var operation = 'metadata';
    final source = catalog((request) {
      if (request.url.path.endsWith('/login')) {
        return json({'session': session});
      }
      if (operation == 'metadata') {
        return json({
          'books': [
            {...item, 'extension': 'pdf'},
          ],
          'hasNext': false,
        });
      }
      return http.Response.bytes(
        Uint8List.fromList([1, 2, 3, 4]),
        200,
        headers: {'content-type': 'application/epub+zip'},
      );
    });
    await expectLater(
      source.search(query: 'livro'),
      throwsA(isA<ApiException>()),
    );
    await source.login('fixture@example.invalid', 'fixture-password');
    operation = 'zip';
    await expectLater(source.download(book), throwsFormatException);
  });

  test(
    'timeout is bounded and error messages do not reveal request credentials',
    () async {
      final pending = Completer<http.Response>();
      final source = catalog(
        (_) => pending.future,
        timeout: const Duration(milliseconds: 10),
      );
      await expectLater(
        source.login('fixture@example.invalid', 'fixture-password'),
        throwsA(
          isA<ApiException>().having(
            (error) => error.message,
            'timeout',
            contains('Tempo esgotado'),
          ),
        ),
      );
      pending.complete(json({'session': session}));
      await Future<void>.delayed(Duration.zero);
      expect(source.isAuthenticated, isFalse);
    },
  );

  for (final mode in ['declared size', 'stream size', 'truncated']) {
    test('download rejects $mode before returning library bytes', () async {
      final client = MockClient.streaming((request, _) async {
        if (request.url.path.endsWith('/login')) {
          return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode({'session': session}))),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.StreamedResponse(
          mode == 'stream size'
              ? Stream.fromIterable([Uint8List(maxBookBytes), Uint8List(1)])
              : Stream.value([0x50, 0x4b, 0x03, 0x04]),
          200,
          contentLength: switch (mode) {
            'declared size' => maxBookBytes + 1,
            'truncated' => 10,
            _ => null,
          },
          headers: {'content-type': 'application/epub+zip'},
        );
      });
      final source = ZLibraryCatalog(client: client, endpoint: endpoint);
      addTearDown(() {
        source.dispose();
        client.close();
      });
      await source.login('fixture@example.invalid', 'fixture-password');
      await expectLater(source.download(book), throwsA(isA<ApiException>()));
    });
  }
}
