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
import 'package:leitura_anywhere/data/library.dart';

// These bytes exercise the ZIP transport gate, not full EPUB conformance.
Uint8List zipBytes() => Uint8List.fromList([0x50, 0x4b, 0x03, 0x04, 1, 2, 3]);

const invalidReadingAnchors = <String, List<Object>>{
  'textOffset': [-1, 1.0, '12', true, <int>[], double.nan, double.infinity],
  'progress': [
    -0.1,
    1.1,
    double.nan,
    double.infinity,
    -double.infinity,
    '0.5',
    true,
    <int>[],
  ],
};

Book sampleBook({String id = 'gutenberg:123'}) => Book(
  id: id,
  title: 'Livro de teste',
  author: 'Autora',
  source: 'Projeto Gutenberg',
  coverUrl: 'https://www.gutenberg.org/cover.jpg',
  downloadUrl: 'https://www.gutenberg.org/book.epub',
  subjects: ['Literatura'],
);

Map<String, dynamic> gutendexBook() => {
  'id': 123,
  'title': 'Livro de teste',
  'authors': [
    {'name': 'Autora'},
    {'name': 'Outro autor'},
  ],
  'subjects': ['Literatura', 'Ficcao'],
  'formats': {
    'image/jpeg': 'https://www.gutenberg.org/cover.jpg',
    'application/epub+zip': 'https://www.gutenberg.org/book.epub',
    'text/html': 'https://www.gutenberg.org/book.html',
  },
};

http.Response catalogResponse({List<dynamic>? books, String? next}) =>
    http.Response(
      jsonEncode({
        'results': books ?? [gutendexBook()],
        'next': next,
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

void main() {
  group('Book and LocalBook', () {
    test('book metadata round trips and subjects are immutable', () {
      final subjects = ['Literatura'];
      final book = Book(
        id: 'local:1',
        title: 'Titulo',
        author: 'Autor',
        source: 'Importado',
        subjects: subjects,
      );
      subjects.add('Changed');
      expect(book.subjects, ['Literatura']);
      expect(() => book.subjects.add('Changed'), throwsUnsupportedError);
      expect(Book.fromJson(book.toJson()).toJson(), book.toJson());
      expect(book.downloadable, isFalse);
      expect(sampleBook().downloadable, isTrue);
    });

    test('downloadable rejects HTTP, userinfo and missing host', () {
      for (final url in [
        'http://example.org/a.epub',
        'https://user:password@example.org/a.epub',
        'https:///a.epub',
        'javascript:alert(1)',
      ]) {
        final json = sampleBook().toJson()..['downloadUrl'] = url;
        expect(Book.fromJson(json).downloadable, isFalse, reason: url);
      }
    });

    test('book parser rejects malformed required fields and subjects', () {
      for (final change in <String, dynamic>{
        'id': null,
        'title': 42,
        'author': '',
        'source': [],
        'subjects': [1],
        'downloadUrl': false,
      }.entries) {
        final json = sampleBook().toJson()..[change.key] = change.value;
        expect(() => Book.fromJson(json), throwsFormatException);
      }
    });

    test('local metadata excludes binaries and retains progress and date', () {
      final bytes = zipBytes();
      final cover = Uint8List.fromList([1, 2, 3]);
      final date = DateTime.utc(2026, 10, 1);
      final local = LocalBook(
        book: sampleBook(),
        bytes: bytes,
        coverBytes: cover,
        section: 2,
        scroll: 0.75,
        textOffset: 123,
        progress: 0.4,
        onDesk: false,
        addedAt: date,
      );
      bytes[0] = 0;
      cover[0] = 9;
      expect(local.bytes[0], 0x50);
      expect(local.coverBytes![0], 1);
      expect(() => local.bytes[0] = 0, throwsUnsupportedError);
      final json = local.toJson();
      expect(json.containsKey('bytes'), isFalse);
      expect(json.containsKey('coverBytes'), isFalse);
      expect(() => jsonEncode(json), returnsNormally);
      final restored = LocalBook.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
        bytes: local.bytes,
        coverBytes: local.coverBytes,
      );
      expect(restored.toJson(), json);
      expect(restored.bytes, local.bytes);
      expect(restored.textOffset, 123);
      expect(restored.progress, 0.4);
      final changed = restored.copyWith(section: 3, scroll: 42, onDesk: true);
      expect(changed.section, 3);
      expect(changed.scroll, 42);
      expect(changed.onDesk, isTrue);
      expect(changed.addedAt, date);
      expect(changed.textOffset, 123);
      expect(changed.progress, 0.4);
      expect(changed.bytes, same(restored.bytes));
      expect(changed.coverBytes, same(restored.coverBytes));
      final anchored = changed.copyWith(textOffset: 456, progress: 0.6);
      expect(anchored.textOffset, 456);
      expect(anchored.progress, 0.6);
      expect(anchored.section, 3);
      expect(anchored.scroll, 42);
      expect(anchored.bytes, same(changed.bytes));
      expect(anchored.coverBytes, same(changed.coverBytes));
      expect(changed.textOffset, 123);
      expect(changed.progress, 0.4);
      expect(restored.section, 2);
    });

    test('legacy metadata and null anchors preserve section and scroll', () {
      final local = LocalBook(
        book: sampleBook(),
        bytes: zipBytes(),
        section: 7,
        scroll: 87.5,
      );
      expect(local.textOffset, isNull);
      expect(local.progress, isNull);
      for (final json in [
        local.toJson(),
        local.toJson()
          ..remove('textOffset')
          ..remove('progress'),
      ]) {
        final restored = LocalBook.fromJson(json, bytes: local.bytes);
        expect(restored.section, 7);
        expect(restored.scroll, 87.5);
        expect(restored.textOffset, isNull);
        expect(restored.progress, isNull);
      }
    });

    test('anchor bounds validate constructors, copies and JSON', () {
      final local = LocalBook(book: sampleBook(), bytes: zipBytes());
      for (final progress in [0.0, 1.0]) {
        final anchored = LocalBook(
          book: sampleBook(),
          bytes: zipBytes(),
          textOffset: 0,
          progress: progress,
        );
        expect(anchored.textOffset, 0);
        expect(anchored.progress, progress);
        expect(
          local.copyWith(textOffset: 0, progress: progress).progress,
          progress,
        );
        final json = anchored.toJson()..['progress'] = progress.toInt();
        expect(LocalBook.fromJson(json, bytes: local.bytes).progress, progress);
      }
      expect(
        () => LocalBook(book: sampleBook(), bytes: zipBytes(), textOffset: -1),
        throwsFormatException,
      );
      expect(() => local.copyWith(textOffset: -1), throwsFormatException);
      for (final progress in [
        -0.1,
        1.1,
        double.nan,
        double.infinity,
        -double.infinity,
      ]) {
        expect(
          () => LocalBook(
            book: sampleBook(),
            bytes: zipBytes(),
            progress: progress,
          ),
          throwsFormatException,
        );
        expect(() => local.copyWith(progress: progress), throwsFormatException);
      }
      for (final entry in invalidReadingAnchors.entries) {
        for (final value in entry.value) {
          final json = local.toJson()..[entry.key] = value;
          expect(
            () => LocalBook.fromJson(json, bytes: local.bytes),
            throwsFormatException,
            reason: '${entry.key}: $value',
          );
        }
      }
    });

    test(
      'invalid ZIP, oversize imports and corrupt positions are rejected',
      () {
        for (final bytes in [
          Uint8List(0),
          Uint8List.fromList([1, 2, 3, 4]),
        ]) {
          expect(
            () => LocalBook(book: sampleBook(), bytes: bytes),
            throwsFormatException,
          );
        }
        expect(
          () =>
              LocalBook(book: sampleBook(), bytes: Uint8List(maxBookBytes + 1)),
          throwsFormatException,
        );
        for (final scroll in [double.nan, double.infinity, -1.0]) {
          expect(
            () => LocalBook(
              book: sampleBook(),
              bytes: zipBytes(),
              scroll: scroll,
            ),
            throwsFormatException,
          );
        }
        final local = LocalBook(book: sampleBook(), bytes: zipBytes());
        expect(() => local.copyWith(section: -1), throwsFormatException);
        final json = local.toJson()..['addedAt'] = 'not a date';
        expect(
          () => LocalBook.fromJson(json, bytes: zipBytes()),
          throwsFormatException,
        );
      },
    );
  });

  group('CatalogService', () {
    test(
      'default endpoint, encoding, filters and pagination follow Gutendex',
      () async {
        final requests = <http.Request>[];
        final client = MockClient((request) async {
          requests.add(request);
          return catalogResponse(
            next: request.url.queryParameters['page'] == '2'
                ? 'https://gutendex.com/books/?page=3'
                : null,
          );
        });
        final service = CatalogService(client: client);
        addTearDown(service.dispose);
        addTearDown(client.close);
        final page = await service.search(
          query: '  a\u00e7\u00e3o & mar?  ',
          topic: 'Romance / Portugal',
          page: 2,
        );
        final request = requests.single;
        expect(request.url.scheme, 'https');
        expect(request.url.host, 'gutendex.com');
        expect(request.url.path, '/books/');
        expect(request.url.queryParameters, {
          'languages': 'pt',
          'mime_type': 'application/epub+zip',
          'copyright': 'false',
          'search': 'a\u00e7\u00e3o & mar?',
          'topic': 'Romance / Portugal',
          'page': '2',
        });
        expect(request.followRedirects, isFalse);
        expect(page.page, 2);
        expect(page.hasNext, isTrue);
        final book = page.books.single;
        expect(book.id, 'gutenberg:123');
        expect(book.author, 'Autora, Outro autor');
        expect(book.source, 'Projeto Gutenberg');
        expect(book.subjects, ['Literatura', 'Ficcao']);
        expect(book.coverUrl, 'https://www.gutenberg.org/cover.jpg');
        expect(book.downloadUrl, 'https://www.gutenberg.org/book.epub');
        expect(book.downloadable, isTrue);
        expect((await service.search()).hasNext, isFalse);
        expect(
          requests.last.url.queryParameters.containsKey('search'),
          isFalse,
        );
        expect(requests.last.url.queryParameters.containsKey('topic'), isFalse);
        await expectLater(service.search(page: 0), throwsArgumentError);
      },
    );

    test(
      'custom endpoint keeps generic Gutendex contract and source label',
      () async {
        final client = MockClient((request) async {
          expect(request.url.host, 'catalog.example.org');
          expect(request.url.queryParameters['languages'], 'pt');
          expect(request.url.queryParameters['search'], isNull);
          expect(request.url.queryParameters['topic'], isNull);
          expect(request.url.queryParameters['collection'], 'public');
          return catalogResponse();
        });
        final service = CatalogService(
          client: client,
          endpoint: Uri.parse(
            'https://catalog.example.org/books?search=old&topic=old&collection=public',
          ),
        );
        addTearDown(client.close);
        addTearDown(service.dispose);
        expect(
          (await service.search()).books.single.source,
          'Cat\u00e1logo personalizado',
        );
      },
    );

    test('HTML-only entries remain visible but are not downloadable', () async {
      final item = gutendexBook()
        ..['authors'] = []
        ..['formats'] = {'text/html': 'https://example.org/book.html'};
      final client = MockClient((_) async => catalogResponse(books: [item]));
      final service = CatalogService(client: client);
      addTearDown(client.close);
      addTearDown(service.dispose);
      final book = (await service.search()).books.single;
      expect(book.author, 'Autor desconhecido');
      expect(book.downloadable, isFalse);
      await expectLater(service.download(book), throwsA(isA<ApiException>()));
    });

    test(
      'HTTP and credential URLs in catalog formats are never downloads',
      () async {
        final item = gutendexBook()
          ..['formats'] = {
            'application/epub+zip': 'http://example.org/book.epub',
            'image/jpeg': 'https://user:secret@example.org/cover.jpg',
          };
        final client = MockClient((_) async => catalogResponse(books: [item]));
        final service = CatalogService(client: client);
        addTearDown(client.close);
        addTearDown(service.dispose);
        final book = (await service.search()).books.single;
        expect(book.downloadUrl, isNull);
        expect(book.coverUrl, isNull);
      },
    );

    test('HTTP errors have status and never include response bodies', () async {
      final client = MockClient(
        (_) async => http.Response('PRIVATE BODY', 503),
      );
      final service = CatalogService(client: client);
      addTearDown(client.close);
      addTearDown(service.dispose);
      final matcher = isA<ApiException>()
          .having((error) => error.statusCode, 'status', 503)
          .having(
            (error) => error.toString(),
            'message',
            isNot(contains('PRIVATE BODY')),
          );
      await expectLater(service.search(), throwsA(matcher));
      await expectLater(service.download(sampleBook()), throwsA(matcher));
    });

    test(
      'malformed JSON, shape, book and network failures are ApiException',
      () async {
        for (final body in [
          'not json',
          '[]',
          '{"results": {}, "next": null}',
          jsonEncode({
            'results': [
              {'id': 'wrong'},
            ],
            'next': null,
          }),
        ]) {
          final client = MockClient((_) async => http.Response(body, 200));
          final service = CatalogService(client: client);
          await expectLater(service.search(), throwsA(isA<ApiException>()));
          service.dispose();
          client.close();
        }
        final client = MockClient(
          (_) async => throw http.ClientException('private details'),
        );
        final service = CatalogService(client: client);
        addTearDown(client.close);
        addTearDown(service.dispose);
        await expectLater(service.search(), throwsA(isA<ApiException>()));
        await expectLater(
          service.download(sampleBook()),
          throwsA(isA<ApiException>()),
        );
      },
    );

    test('constructor rejects unsafe custom endpoints', () {
      for (final url in [
        'http://example.org',
        'https://user@example.org',
        '/books',
      ]) {
        expect(
          () => CatalogService(endpoint: Uri.parse(url)),
          throwsA(isA<ApiException>()),
        );
      }
    });

    test(
      'streamed download reports progress and verifies ZIP signature',
      () async {
        final bytes = zipBytes();
        final progress = <double?>[];
        final client = MockClient.streaming((request, _) async {
          expect(request.followRedirects, isFalse);
          expect(request.headers['Accept'], 'application/epub+zip');
          return http.StreamedResponse(
            Stream.fromIterable([bytes.sublist(0, 3), bytes.sublist(3)]),
            200,
            contentLength: bytes.length,
          );
        });
        final service = CatalogService(client: client);
        addTearDown(client.close);
        addTearDown(service.dispose);
        expect(
          await service.download(sampleBook(), onProgress: progress.add),
          bytes,
        );
        expect(progress.first, 0);
        expect(progress, contains(3 / bytes.length));
        expect(progress.last, 1);
      },
    );

    test('unknown content length reports indeterminate progress', () async {
      final progress = <double?>[];
      final client = MockClient.streaming(
        (_, _) async => http.StreamedResponse(Stream.value(zipBytes()), 200),
      );
      final service = CatalogService(client: client);
      addTearDown(client.close);
      addTearDown(service.dispose);
      await service.download(sampleBook(), onProgress: progress.add);
      expect(progress.first, isNull);
      expect(progress.last, 1);
    });

    test('empty, non-ZIP and truncated downloads are rejected', () async {
      for (final bytes in [
        Uint8List(0),
        Uint8List.fromList(utf8.encode('<html>error</html>')),
      ]) {
        final client = MockClient((_) async => http.Response.bytes(bytes, 200));
        final service = CatalogService(client: client);
        await expectLater(
          service.download(sampleBook()),
          throwsA(isA<ApiException>()),
        );
        service.dispose();
        client.close();
      }
      final client = MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          Stream.value(zipBytes()),
          200,
          contentLength: 100,
        ),
      );
      final service = CatalogService(client: client);
      addTearDown(client.close);
      addTearDown(service.dispose);
      await expectLater(
        service.download(sampleBook()),
        throwsA(isA<ApiException>()),
      );
    });

    test(
      'declared oversized downloads are rejected before consuming bytes',
      () async {
        final client = MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            const Stream<List<int>>.empty(),
            200,
            contentLength: maxBookBytes + 1,
          ),
        );
        final service = CatalogService(client: client);
        addTearDown(client.close);
        addTearDown(service.dispose);
        await expectLater(
          service.download(sampleBook()),
          throwsA(
            isA<ApiException>().having(
              (error) => error.message,
              'limit',
              contains('40 MiB'),
            ),
          ),
        );
      },
    );

    test(
      'stream limit applies without Content-Length and cancels input',
      () async {
        var cancelled = false;
        final chunk = Uint8List(1024 * 1024);
        final client = MockClient.streaming((_, _) async {
          final controller = StreamController<List<int>>(
            onCancel: () {
              cancelled = true;
            },
          );
          for (var i = 0; i < 41; i++) {
            controller.add(chunk);
          }
          unawaited(controller.close());
          return http.StreamedResponse(controller.stream, 200);
        });
        final service = CatalogService(client: client);
        addTearDown(client.close);
        addTearDown(service.dispose);
        await expectLater(
          service.download(sampleBook()),
          throwsA(
            isA<ApiException>().having(
              (error) => error.message,
              'limit',
              contains('40 MiB'),
            ),
          ),
        );
        expect(cancelled, isTrue);
      },
    );

    test('request and stalled stream timeouts are readable errors', () async {
      final waitingRequest = Completer<http.Response>();
      final requestClient = MockClient((_) => waitingRequest.future);
      final requestService = CatalogService(
        client: requestClient,
        timeout: const Duration(milliseconds: 20),
      );
      addTearDown(requestClient.close);
      addTearDown(requestService.dispose);
      final requestResult = expectLater(
        requestService.download(sampleBook()),
        throwsA(
          isA<ApiException>().having(
            (error) => error.message,
            'timeout',
            contains('Tempo esgotado'),
          ),
        ),
      );
      await requestResult;
      // Complete the late response so the mock leaves no pending work.
      waitingRequest.complete(http.Response.bytes(zipBytes(), 200));

      final stalled = StreamController<List<int>>();
      final streamClient = MockClient.streaming(
        (_, _) async => http.StreamedResponse(stalled.stream, 200),
      );
      final streamService = CatalogService(
        client: streamClient,
        timeout: const Duration(milliseconds: 20),
      );
      addTearDown(streamClient.close);
      addTearDown(streamService.dispose);
      final streamResult = expectLater(
        streamService.download(sampleBook()),
        throwsA(
          isA<ApiException>().having(
            (error) => error.message,
            'timeout',
            contains('Tempo esgotado'),
          ),
        ),
      );
      await streamResult;
      await stalled.close();
    });

    test('redirects follow relative HTTPS URLs up to three times', () async {
      var requests = 0;
      final client = MockClient((request) async {
        expect(request.followRedirects, isFalse);
        requests++;
        return requests <= 3
            ? http.Response(
                '',
                302,
                headers: {'location': '/redirect-$requests.epub'},
              )
            : http.Response.bytes(zipBytes(), 200);
      });
      final service = CatalogService(client: client);
      addTearDown(client.close);
      addTearDown(service.dispose);
      expect(await service.download(sampleBook()), zipBytes());
      expect(requests, 4);
    });

    test(
      'downgrade, userinfo and invalid redirect URLs are not requested',
      () async {
        for (final target in [
          'http://example.org/book.epub',
          'https://user:secret@example.org/book.epub',
          'https:///',
          'https://example.org:99999/book.epub',
        ]) {
          var requests = 0;
          final client = MockClient((_) async {
            requests++;
            return http.Response('', 302, headers: {'location': target});
          });
          final service = CatalogService(client: client);
          await expectLater(
            service.download(sampleBook()),
            throwsA(isA<ApiException>()),
          );
          expect(requests, 1, reason: target);
          service.dispose();
          client.close();
        }
      },
    );

    test('redirect loops and missing locations are explicit errors', () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response('', 301, headers: {'location': '/loop'});
      });
      final service = CatalogService(client: client);
      addTearDown(client.close);
      addTearDown(service.dispose);
      await expectLater(
        service.download(sampleBook()),
        throwsA(isA<ApiException>()),
      );
      expect(requests, 4);
      final noLocation = MockClient((_) async => http.Response('', 302));
      final other = CatalogService(client: noLocation);
      addTearDown(noLocation.close);
      addTearDown(other.dispose);
      await expectLater(other.search(), throwsA(isA<ApiException>()));
    });

    test(
      'dispose rejects operations but does not close an injected client',
      () async {
        final client = MockClient((_) async => catalogResponse());
        final service = CatalogService(client: client)..dispose();
        addTearDown(client.close);
        service.dispose();
        await expectLater(service.search(), throwsA(isA<ApiException>()));
        expect(
          (await client.get(Uri.https('example.org', '/'))).statusCode,
          200,
        );
      },
    );
  });

  group('Library with real Hive storage', () {
    late Directory directory;
    late Box<dynamic> box;
    late Library library;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('leitura-data-test-');
      Hive.init(directory.path);
      box = await Hive.openBox<dynamic>('books');
      library = Library(box);
    });

    tearDown(() async {
      library.dispose();
      await Hive.close();
      await directory.delete(recursive: true);
    });

    test(
      'atomic binary record is persisted before listeners observe it',
      () async {
        await library.load();
        var notifications = 0;
        library.addListener(() {
          notifications++;
          final record = box.get(sampleBook().id) as Map;
          expect(record['bytes'], isA<Uint8List>());
          expect(record['coverBytes'], isA<Uint8List>());
          expect((record['metadata'] as Map).containsKey('bytes'), isFalse);
          expect(library.find(sampleBook().id), isNotNull);
        });
        await library.add(
          sampleBook(),
          zipBytes(),
          coverBytes: Uint8List.fromList([1, 2]),
        );
        expect(notifications, 1);
        expect(box.keys.toList(), [sampleBook().id]);
      },
    );

    test(
      'close and reopen restores binaries, progress, desk and date',
      () async {
        await library.add(
          sampleBook(),
          zipBytes(),
          coverBytes: Uint8List.fromList([7, 8]),
        );
        final addedAt = library.books.single.addedAt;
        await library.updatePosition(
          sampleBook().id,
          4,
          128.5,
          textOffset: 234,
          progress: 0.75,
        );
        await library.setOnDesk(sampleBook().id, false);
        library.dispose();
        await box.close();
        box = await Hive.openBox<dynamic>('books');
        library = Library(box);
        await library.load();
        final restored = library.books.single;
        expect(restored.book.toJson(), sampleBook().toJson());
        expect(restored.bytes, zipBytes());
        expect(restored.coverBytes, [7, 8]);
        expect(restored.section, 4);
        expect(restored.scroll, 128.5);
        expect(restored.textOffset, 234);
        expect(restored.progress, 0.75);
        expect(restored.onDesk, isFalse);
        expect(restored.addedAt, addedAt);
      },
    );

    test(
      'newest first, missing lookup, immutable list and remove persist',
      () async {
        final old = LocalBook(
          book: sampleBook(id: 'old'),
          bytes: zipBytes(),
          addedAt: DateTime.utc(2020),
        );
        final recent = LocalBook(
          book: sampleBook(id: 'recent'),
          bytes: zipBytes(),
          addedAt: DateTime.utc(2026),
        );
        for (final item in [recent, old]) {
          await box.put(item.book.id, {
            'metadata': item.toJson(),
            'bytes': item.bytes,
            'coverBytes': null,
          });
        }
        await library.load();
        expect(library.books.map((item) => item.book.id), ['recent', 'old']);
        expect(() => library.books.clear(), throwsUnsupportedError);
        expect(library.find('missing'), isNull);
        await library.remove('recent');
        expect(box.containsKey('recent'), isFalse);
        await library.load();
        expect(library.books.single.book.id, 'old');
        await library.remove('missing');
      },
    );

    test(
      'legacy metadata and state survive reopening before migration',
      () async {
        final local = LocalBook(
          book: sampleBook(),
          bytes: zipBytes(),
          section: 2,
          scroll: 45.5,
        );
        final record = {
          'metadata': local.toJson()
            ..remove('textOffset')
            ..remove('progress'),
          'bytes': local.bytes,
        };
        await box.put(local.book.id, record);
        final legacyState = {'section': 4, 'scroll': 125.5, 'onDesk': false};
        await box.put('@state/${local.book.id}', legacyState);
        library.dispose();
        await box.close();
        box = await Hive.openBox<dynamic>('books');
        library = Library(box);
        await library.load();
        final restored = library.books.single;
        expect(restored.section, 4);
        expect(restored.scroll, 125.5);
        expect(restored.onDesk, isFalse);
        expect(restored.textOffset, isNull);
        expect(restored.progress, isNull);
        expect(box.get(local.book.id), record);
        expect(box.get('@state/${local.book.id}'), legacyState);
        await box.delete('@state/${local.book.id}');
        await library.load();
        expect(library.books.single.section, 2);
        expect(library.books.single.scroll, 45.5);
        expect(library.books.single.textOffset, isNull);
        expect(library.books.single.progress, isNull);
        await library.updatePosition(
          local.book.id,
          2,
          45.5,
          textOffset: 80,
          progress: 0.2,
        );
        await library.load();
        expect(library.books.single.textOffset, 80);
        expect(library.books.single.progress, 0.2);
        expect(box.get(local.book.id), record);
      },
    );

    test(
      'optional state anchors retain metadata anchors when absent',
      () async {
        final local = LocalBook(
          book: sampleBook(),
          bytes: zipBytes(),
          textOffset: 123,
          progress: 0.4,
        );
        await box.put(local.book.id, {
          'metadata': local.toJson(),
          'bytes': local.bytes,
        });
        for (final anchors in <Map<String, dynamic>>[
          {},
          {'textOffset': null, 'progress': null},
          {'textOffset': 0, 'progress': 0},
          {'textOffset': 200, 'progress': 1},
        ]) {
          await box.put('@state/${local.book.id}', {
            'section': 1,
            'scroll': 25,
            'onDesk': true,
            ...anchors,
          });
          await library.load();
          expect(library.books.single.textOffset, anchors['textOffset'] ?? 123);
          expect(library.books.single.progress, anchors['progress'] ?? 0.4);
          expect(library.books.single.section, 1);
          expect(library.books.single.scroll, 25);
        }
      },
    );

    test('duplicate add retains progress, date and existing cover', () async {
      await library.add(
        sampleBook(),
        zipBytes(),
        coverBytes: Uint8List.fromList([8]),
      );
      await library.updatePosition(
        sampleBook().id,
        3,
        0.5,
        textOffset: 345,
        progress: 0.6,
      );
      await library.setOnDesk(sampleBook().id, false);
      final date = library.books.single.addedAt;
      await library.add(sampleBook(), zipBytes());
      expect(library.books, hasLength(1));
      expect(library.books.single.section, 3);
      expect(library.books.single.scroll, 0.5);
      expect(library.books.single.textOffset, 345);
      expect(library.books.single.progress, 0.6);
      expect(library.books.single.onDesk, isFalse);
      expect(library.books.single.addedAt, date);
      expect(library.books.single.coverBytes, [8]);
      final record = box.get(sampleBook().id) as Map;
      expect((record['metadata'] as Map)['textOffset'], 345);
      expect((record['metadata'] as Map)['progress'], 0.6);
      await library.load();
      expect(library.books.single.textOffset, 345);
      expect(library.books.single.progress, 0.6);
    });

    test('concurrent updates serialize without losing fields', () async {
      await library.add(sampleBook(), zipBytes());
      var notifications = 0;
      library.addListener(() {
        notifications++;
        final local = library.books.single;
        expect(box.get('@state/${local.book.id}'), {
          'section': local.section,
          'scroll': local.scroll,
          'textOffset': local.textOffset,
          'progress': local.progress,
          'onDesk': local.onDesk,
        });
      });
      await Future.wait([
        library.updatePosition(
          sampleBook().id,
          9,
          42,
          textOffset: 900,
          progress: 0.9,
        ),
        library.setOnDesk(sampleBook().id, false),
        library.updatePosition(sampleBook().id, 10, 21, textOffset: 100),
        library.updatePosition(sampleBook().id, 10, 22, progress: 1),
      ]);
      expect(notifications, 4);
      await library.load();
      expect(library.books.single.section, 10);
      expect(library.books.single.scroll, 22);
      expect(library.books.single.textOffset, 100);
      expect(library.books.single.progress, 1);
      expect(library.books.single.onDesk, isFalse);
    });

    test(
      'progress checkpoints write only state and share binary snapshots',
      () async {
        await library.add(
          sampleBook(),
          zipBytes(),
          coverBytes: Uint8List.fromList([8]),
        );
        final original = library.books.single;
        final record = box.get(original.book.id);
        final events = expectLater(
          box.watch().map((event) => event.key).take(3),
          emitsInOrder(List.filled(3, '@state/${original.book.id}')),
        );
        await library.updatePosition(
          original.book.id,
          1,
          20,
          textOffset: 0,
          progress: 0,
        );
        await library.setOnDesk(original.book.id, false);
        await library.updatePosition(original.book.id, 2, 30);
        await events;
        expect(box.get(original.book.id), same(record));
        final updated = library.books.single;
        expect(updated.bytes, same(original.bytes));
        expect(updated.coverBytes, same(original.coverBytes));
        expect(updated.textOffset, 0);
        expect(updated.progress, 0);
      },
    );

    test(
      'invalid optional metadata and state preserve disk and memory',
      () async {
        await library.add(sampleBook(), zipBytes());
        await library.updatePosition(
          sampleBook().id,
          2,
          30,
          textOffset: 80,
          progress: 0.2,
        );
        final original = library.books.single;
        final record = box.get(original.book.id) as Map;
        final stateKey = '@state/${original.book.id}';
        final state = box.get(stateKey) as Map;
        var notifications = 0;
        library.addListener(() => notifications++);
        for (final entry in invalidReadingAnchors.entries) {
          for (final value in entry.value) {
            for (final inState in [false, true]) {
              final key = inState ? stateKey : original.book.id;
              final corrupt = inState
                  ? {...state, entry.key: value}
                  : {
                      ...record,
                      'metadata': {
                        ...record['metadata'] as Map,
                        entry.key: value,
                      },
                    };
              await box.put(key, corrupt);
              await expectLater(
                library.load(),
                throwsA(isA<LibraryException>()),
                reason: '$key ${entry.key}: $value',
              );
              expect(box.get(key), same(corrupt));
              expect(library.books.single, same(original));
              expect(notifications, 0);
              await box.put(key, inState ? state : record);
            }
          }
        }
        await library.load();
        expect(library.books.single.textOffset, 80);
        expect(library.books.single.progress, 0.2);
        expect(notifications, 1);
      },
    );

    test(
      'invalid anchor updates do not write, notify or poison the queue',
      () async {
        await library.add(sampleBook(), zipBytes());
        await library.updatePosition(
          sampleBook().id,
          2,
          30,
          textOffset: 80,
          progress: 0.2,
        );
        final original = library.books.single;
        final stateKey = '@state/${original.book.id}';
        final state = box.get(stateKey);
        var notifications = 0;
        library.addListener(() => notifications++);
        final invalidUpdates = [
          library.updatePosition(original.book.id, 3, 40, textOffset: -1),
          for (final progress in [
            -0.1,
            1.1,
            double.nan,
            double.infinity,
            -double.infinity,
          ])
            library.updatePosition(original.book.id, 3, 40, progress: progress),
        ];
        await Future.wait(
          invalidUpdates.map(
            (future) => expectLater(future, throwsA(isA<LibraryException>())),
          ),
        );
        expect(library.books.single, same(original));
        expect(box.get(stateKey), same(state));
        expect(notifications, 0);
        await library.updatePosition(
          original.book.id,
          3,
          40,
          textOffset: 100,
          progress: 0.3,
        );
        expect(library.books.single.textOffset, 100);
        expect(library.books.single.progress, 0.3);
        expect(notifications, 1);
      },
    );

    test(
      'legacy books have singleton groups without creating a record',
      () async {
        await library.add(sampleBook(id: 'a'), zipBytes());
        await library.load();
        expect(library.groupFor('a'), [library.find('a')]);
        expect(library.groupFor('missing'), isEmpty);
        expect(() => library.groupFor('a').clear(), throwsUnsupportedError);
        expect(box.containsKey('@groups'), isFalse);
      },
    );

    test(
      'grouping merges whole groups and preserves books and progress',
      () async {
        for (final id in ['a', 'b', 'c', 'd', 'e', 'f']) {
          await library.add(sampleBook(id: id), zipBytes());
        }
        await library.updatePosition('a', 7, 23.5);
        await library.setOnDesk('a', false);
        final original = library.find('a');
        final records = box.toMap();
        await library.groupBooks('e', 'f');
        await library.groupBooks('a', 'b');
        await library.groupBooks('c', 'd');
        await library.groupBooks('b', 'c');
        await library.groupBooks('a', 'd');
        for (final id in ['a', 'b', 'c', 'd']) {
          expect(library.groupFor(id).map((local) => local.book.id), [
            'a',
            'b',
            'c',
            'd',
          ]);
        }
        expect(library.groupFor('e').map((local) => local.book.id), ['e', 'f']);
        expect(box.get('@groups'), [
          ['e', 'f'],
          ['a', 'b', 'c', 'd'],
        ]);
        expect(library.find('a'), same(original));
        for (final entry in records.entries) {
          expect(box.get(entry.key), entry.value);
        }
        expect(box.keys.where((key) => !records.containsKey(key)), ['@groups']);
        expect(() => library.groupFor('a').clear(), throwsUnsupportedError);
      },
    );

    test(
      'concurrent grouping serializes and notifies after persistence',
      () async {
        for (final id in ['a', 'b', 'c', 'd']) {
          await library.add(sampleBook(id: id), zipBytes());
        }
        var notifications = 0;
        library.addListener(() {
          notifications++;
          final groups = box.get('@groups') as List;
          for (final group in groups.cast<List>()) {
            expect(
              library
                  .groupFor(group.first as String)
                  .map((local) => local.book.id),
              group,
            );
          }
        });
        await Future.wait([
          library.groupBooks('a', 'b'),
          library.groupBooks('c', 'd'),
          library.groupBooks('b', 'c'),
          library.ungroupBook('d'),
        ]);
        expect(notifications, 4);
        expect(box.get('@groups'), [
          ['a', 'b', 'c'],
        ]);
        expect(library.groupFor('d'), [library.find('d')]);
      },
    );

    test('ungroup removes only one member and dissolves pairs', () async {
      for (final id in ['a', 'b', 'c', 'd', 'e']) {
        await library.add(sampleBook(id: id), zipBytes());
      }
      await library.groupBooks('a', 'b');
      await library.groupBooks('b', 'c');
      await library.groupBooks('d', 'e');
      await library.ungroupBook('b');
      expect(library.groupFor('b'), [library.find('b')]);
      expect(box.get('@groups'), [
        ['a', 'c'],
        ['d', 'e'],
      ]);
      await library.ungroupBook('a');
      expect(library.groupFor('a'), [library.find('a')]);
      expect(library.groupFor('c'), [library.find('c')]);
      expect(box.get('@groups'), [
        ['d', 'e'],
      ]);
      await library.ungroupBook('a');
      await library.ungroupBook('d');
      expect(box.get('@groups'), isEmpty);
      expect(library.books, hasLength(5));
    });

    test('groups and ungrouping survive closing and reopening Hive', () async {
      for (final id in ['a', 'b', 'c', 'd', 'e']) {
        await library.add(sampleBook(id: id), zipBytes());
      }
      await library.groupBooks('a', 'b');
      await library.groupBooks('a', 'c');
      await library.groupBooks('d', 'e');
      await library.ungroupBook('b');
      await library.ungroupBook('d');
      library.dispose();
      await box.close();
      box = await Hive.openBox<dynamic>('books');
      library = Library(box);
      await library.load();
      expect(library.books, hasLength(5));
      expect(library.groupFor('c').map((local) => local.book.id), ['a', 'c']);
      for (final id in ['b', 'd', 'e']) {
        expect(library.groupFor(id), [library.find(id)]);
      }
      expect(box.get('@groups'), [
        ['a', 'c'],
      ]);
    });

    test(
      'group operations load existing books before validating IDs',
      () async {
        for (final id in ['a', 'b', 'c']) {
          await library.add(sampleBook(id: id), zipBytes());
        }
        library.dispose();
        library = Library(box);
        await library.groupBooks('a', 'b');
        library.dispose();
        library = Library(box);
        await library.ungroupBook('a');
        expect(library.groupFor('b'), [library.find('b')]);
        expect(box.get('@groups'), isEmpty);
      },
    );

    test(
      'invalid group IDs fail without writes and do not poison queue',
      () async {
        for (final id in ['a', 'b']) {
          await library.add(sampleBook(id: id), zipBytes());
        }
        var notifications = 0;
        library.addListener(() => notifications++);
        for (final pair in [
          ['a', 'a'],
          ['missing', 'a'],
          ['a', 'missing'],
          ['', 'b'],
          ['a', '@groups'],
        ]) {
          await expectLater(
            library.groupBooks(pair[0], pair[1]),
            throwsA(isA<LibraryException>()),
          );
        }
        await expectLater(
          library.ungroupBook('missing'),
          throwsA(isA<LibraryException>()),
        );
        expect(box.containsKey('@groups'), isFalse);
        expect(notifications, 0);
        await library.groupBooks('a', 'b');
        expect(notifications, 1);
        expect(library.groupFor('a'), hasLength(2));
      },
    );

    test(
      'reserved group key cannot be overwritten or removed as a book',
      () async {
        for (final id in ['a', 'b']) {
          await library.add(sampleBook(id: id), zipBytes());
        }
        await library.groupBooks('a', 'b');
        await expectLater(
          library.add(sampleBook(id: '@groups'), zipBytes()),
          throwsA(isA<LibraryException>()),
        );
        await library.remove('@groups');
        expect(box.get('@groups'), [
          ['a', 'b'],
        ]);
        expect(library.books, hasLength(2));
      },
    );

    test(
      'removed books and stale references never appear in group lookup',
      () async {
        for (final id in ['a', 'b', 'c']) {
          await library.add(sampleBook(id: id), zipBytes());
        }
        await library.groupBooks('a', 'b');
        await library.groupBooks('a', 'c');
        final persisted = box.get('@groups');
        await library.remove('b');
        expect(library.groupFor('b'), isEmpty);
        expect(library.groupFor('a').map((local) => local.book.id), ['a', 'c']);
        await library.remove('c');
        expect(library.groupFor('a'), [library.find('a')]);
        var writes = 0;
        final subscription = box.watch().listen((_) => writes++);
        addTearDown(subscription.cancel);
        await library.load();
        expect(library.groupFor('a'), [library.find('a')]);
        expect(library.groupFor('b'), isEmpty);
        expect(box.get('@groups'), persisted);
        expect(writes, 0);
      },
    );

    test(
      'loading stale group references filters members without repairing disk',
      () async {
        for (final id in ['a', 'b', 'c']) {
          await library.add(sampleBook(id: id), zipBytes());
        }
        final groups = [
          ['missing', 'a', 'b'],
          ['c', 'also-missing'],
          ['absent-1', 'absent-2'],
        ];
        await box.put('@groups', groups);
        var writes = 0;
        final subscription = box.watch().listen((_) => writes++);
        addTearDown(subscription.cancel);
        await library.load();
        expect(library.groupFor('b').map((local) => local.book.id), ['a', 'b']);
        expect(library.groupFor('c'), [library.find('c')]);
        expect(library.groupFor('missing'), isEmpty);
        expect(box.get('@groups'), groups);
        expect(writes, 0);
      },
    );

    test(
      'corrupt groups preserve storage, books and previously loaded groups',
      () async {
        for (final id in ['a', 'b']) {
          await library.add(sampleBook(id: id), zipBytes());
        }
        await library.groupBooks('a', 'b');
        final original = library.find('a');
        var notifications = 0;
        library.addListener(() => notifications++);
        for (final corrupt in <dynamic>[
          null,
          'broken',
          {'a': 'b'},
          ['a', 'b'],
          [null],
          [[]],
          [
            ['a'],
          ],
          [
            ['a', 7],
          ],
          [
            ['a', ' '],
          ],
          [
            ['a', 'a'],
          ],
          [
            ['a', 'b'],
            ['b', 'missing'],
          ],
        ]) {
          await box.put('@groups', corrupt);
          await expectLater(
            library.load(),
            throwsA(
              isA<LibraryException>().having(
                (error) => error.message,
                'key',
                contains('@groups'),
              ),
            ),
          );
          expect(box.containsKey('@groups'), isTrue);
          expect(box.get('@groups'), corrupt);
          expect(library.find('a'), same(original));
          expect(library.groupFor('a').map((local) => local.book.id), [
            'a',
            'b',
          ]);
          expect(notifications, 0);
        }
        await box.delete('@groups');
        await library.load();
        expect(library.groupFor('a'), [library.find('a')]);
        expect(notifications, 1);
      },
    );

    test('group write failures preserve memory and do not notify', () async {
      for (final id in ['a', 'b', 'c']) {
        await library.add(sampleBook(id: id), zipBytes());
      }
      await library.groupBooks('a', 'b');
      var notifications = 0;
      library.addListener(() => notifications++);
      await box.close();
      await expectLater(
        library.groupBooks('a', 'c'),
        throwsA(isA<LibraryException>()),
      );
      await expectLater(
        library.ungroupBook('a'),
        throwsA(isA<LibraryException>()),
      );
      expect(library.groupFor('a').map((local) => local.book.id), ['a', 'b']);
      expect(library.groupFor('c'), [library.find('c')]);
      expect(notifications, 0);
    });

    test(
      'bad imports and position errors do not poison future operations',
      () async {
        await expectLater(
          library.add(sampleBook(), Uint8List(0)),
          throwsFormatException,
        );
        await expectLater(
          library.add(sampleBook(), Uint8List(maxBookBytes + 1)),
          throwsFormatException,
        );
        expect(box.isEmpty, isTrue);
        await library.add(sampleBook(), zipBytes());
        await expectLater(
          library.updatePosition(sampleBook().id, -1, 0),
          throwsA(isA<LibraryException>()),
        );
        await expectLater(
          library.setOnDesk('missing', true),
          throwsA(isA<LibraryException>()),
        );
        await library.updatePosition(sampleBook().id, 1, 10);
        expect(library.books.single.section, 1);
      },
    );

    test(
      'corrupt entry preserves disk and previously loaded snapshot',
      () async {
        await library.add(sampleBook(), zipBytes());
        final corrupt = {
          'metadata': 'broken',
          'bytes': Uint8List.fromList([0]),
        };
        await box.put('broken', corrupt);
        var notifications = 0;
        library.addListener(() {
          notifications++;
        });
        await expectLater(
          library.load(),
          throwsA(
            isA<LibraryException>().having(
              (error) => error.message,
              'key',
              contains('broken'),
            ),
          ),
        );
        expect(box.get('broken'), corrupt);
        expect(box.length, 2);
        expect(library.books.single.book.id, sampleBook().id);
        expect(notifications, 0);
        // Only explicit external repair removes the bad entry, never load().
        await box.delete('broken');
        await library.load();
        expect(library.books.single.book.id, sampleBook().id);
      },
    );

    test(
      'corrupt binary and metadata ID mismatch cannot reset storage',
      () async {
        final local = LocalBook(book: sampleBook(), bytes: zipBytes());
        for (final record in [
          {
            'metadata': local.toJson(),
            'bytes': [80, 75, 3, 4],
          },
          {
            'metadata': local.toJson(),
            'bytes': Uint8List.fromList([0, 0, 0, 0]),
          },
          {'metadata': local.toJson(), 'bytes': local.bytes},
        ]) {
          await box.put('wrong-id', record);
          await expectLater(library.load(), throwsA(isA<LibraryException>()));
          expect(box.containsKey('wrong-id'), isTrue);
        }
      },
    );

    test('write failure does not update memory or notify listeners', () async {
      await library.add(sampleBook(), zipBytes());
      await library.updatePosition(
        sampleBook().id,
        2,
        30,
        textOffset: 80,
        progress: 0.2,
      );
      final original = library.books.single;
      var notifications = 0;
      library.addListener(() {
        notifications++;
      });
      await box.close();
      await expectLater(
        library.updatePosition(
          sampleBook().id,
          99,
          1,
          textOffset: 999,
          progress: 1,
        ),
        throwsA(isA<LibraryException>()),
      );
      await expectLater(
        library.remove(sampleBook().id),
        throwsA(isA<LibraryException>()),
      );
      expect(library.books.single, same(original));
      expect(library.books.single.section, 2);
      expect(library.books.single.textOffset, 80);
      expect(library.books.single.progress, 0.2);
      expect(notifications, 0);
      box = await Hive.openBox<dynamic>('books');
      final state = box.get('@state/${sampleBook().id}') as Map;
      expect(state['section'], 2);
      expect(state['scroll'], 30);
      expect(state['textOffset'], 80);
      expect(state['progress'], 0.2);
    });
  });
}
