import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:leitura_anywhere/data/book.dart';
import 'package:leitura_anywhere/reader/document_cache.dart';
import 'package:leitura_anywhere/reader/epub_document.dart';

import 'support/epub_fixture.dart';

// Transport-valid bytes for injected parsers; real-parser tests use fixtureEpub.
Uint8List _bytes([int id = 0]) =>
    Uint8List.fromList([0x50, 0x4b, 0x03, 0x04, id]).asUnmodifiableView();

Uint8List _fixtureWithImages({bool batched = false}) {
  final archive = ZipDecoder().decodeBytes(fixtureEpub());
  void text(String name, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  var package = utf8.decode(archive.findFile('book.opf')!.content as List<int>);
  package = package
      .replaceFirst(
        '</metadata>',
        '<meta name="cover" content="cover"/></metadata>',
      )
      .replaceFirst(
        '</manifest>',
        '<item id="cover" href="local.png" media-type="image/png"/></manifest>',
      );
  if (batched) {
    package = package.replaceFirst(
      '<itemref idref="one"/>',
      List.filled(30, '<itemref idref="one"/>').join(),
    );
    final padding = Uint8List(8192);
    for (var i = 0; i < 400; i++) {
      archive.addFile(ArchiveFile('unused-$i.bin', padding.length, padding));
    }
    text(
      'one.xhtml',
      '<html><body><h1>First</h1>${List.filled(100, '<p>Text in a chapter.</p>').join()}<img src="local.png"/></body></html>',
    );
  } else {
    final page = utf8.decode(
      archive.findFile('one.xhtml')!.content as List<int>,
    );
    text(
      'one.xhtml',
      page.replaceFirst('</body>', '<img src="local.png"/></body>'),
    );
  }
  text('book.opf', package);
  archive.addFile(
    ArchiveFile('local.png', 4, Uint8List.fromList([1, 2, 3, 4])),
  );
  return Uint8List.fromList(ZipEncoder().encode(archive)!).asUnmodifiableView();
}

EpubDocument _document({Uint8List? image, String text = 'Text'}) =>
    EpubDocument(
      title: 'Title',
      author: 'Author',
      cover: image,
      sections: [
        EpubSection(
          title: 'Section',
          blocks: [
            EpubBlock(text: text, image: image),
            if (image != null) EpubBlock(text: 'Same image', image: image),
          ],
        ),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(EpubDocumentCache.resetForTesting);
  tearDown(EpubDocumentCache.resetForTesting);

  test(
    'deduplicates the exact future and reuses a completed document',
    () async {
      final gate = Completer<EpubDocument>();
      var calls = 0;
      EpubDocumentCache.resetForTesting(
        parser: (_) {
          calls++;
          return gate.future;
        },
      );
      final bytes = _bytes();
      // Pin the conservative read-only detection on every tested SDK backend.
      expect(identical(bytes, bytes.asUnmodifiableView()), isTrue);
      final first = EpubDocumentCache.load(bytes);
      final second = EpubDocumentCache.load(bytes);
      final warm = EpubDocumentCache.warm(bytes);
      expect(identical(first, second), isTrue);
      expect(calls, 1);
      final document = _document();
      gate.complete(document);
      expect(await first, same(document));
      await warm;
      expect(EpubDocumentCache.load(bytes), same(first));
      expect(calls, 1);
    },
  );

  test('equal contents with different identities are not conflated', () async {
    var calls = 0;
    EpubDocumentCache.resetForTesting(
      parser: (_) async {
        calls++;
        return _document();
      },
    );
    final a = _bytes();
    final b = _bytes();
    expect(
      await EpubDocumentCache.load(a),
      isNot(same(await EpubDocumentCache.load(b))),
    );
    expect(calls, 2);
  });

  test(
    'LocalBook snapshots and copyWith reuse the same cache identity',
    () async {
      final input = fixtureEpub();
      final local = LocalBook(
        book: Book(id: '1', title: 'Title', author: 'Author', source: 'Test'),
        bytes: input,
      );
      input.fillRange(0, input.length, 0);
      final document = await EpubDocumentCache.load(local.bytes);
      final updated = local.copyWith(section: 1);
      expect(updated.bytes, same(local.bytes));
      expect(await EpubDocumentCache.load(updated.bytes), same(document));
    },
  );

  test('evicts least recently used documents by count', () async {
    final calls = <int, int>{};
    EpubDocumentCache.resetForTesting(
      maxDocuments: 2,
      parser: (bytes) async {
        calls.update(bytes.last, (count) => count + 1, ifAbsent: () => 1);
        return _document();
      },
    );
    final a = _bytes(1), b = _bytes(2), c = _bytes(3);
    final first = await EpubDocumentCache.load(a);
    await EpubDocumentCache.load(b);
    expect(await EpubDocumentCache.load(a), same(first));
    await EpubDocumentCache.load(c);
    expect(await EpubDocumentCache.load(a), same(first));
    await EpubDocumentCache.load(b);
    expect(calls, {1: 1, 2: 2, 3: 1});
  });

  test('evicts by estimated memory even below document count limit', () async {
    var calls = 0;
    EpubDocumentCache.resetForTesting(
      maxDocuments: 10,
      maxEstimatedBytes: 1800,
      parser: (_) async {
        calls++;
        return _document(image: Uint8List(700));
      },
    );
    final a = _bytes(1), b = _bytes(2);
    final first = await EpubDocumentCache.load(a);
    expect(await EpubDocumentCache.load(a), same(first));
    await EpubDocumentCache.load(b);
    expect(await EpubDocumentCache.load(a), isNot(same(first)));
    expect(calls, 3);
  });

  test('counts source backing buffers, not just source views', () async {
    var calls = 0;
    EpubDocumentCache.resetForTesting(
      maxEstimatedBytes: 2000,
      parser: (_) async {
        calls++;
        return _document();
      },
    );
    final backing = Uint8List(3000)..setAll(0, _bytes());
    final view = Uint8List.sublistView(backing, 0, 5).asUnmodifiableView();
    await EpubDocumentCache.load(view);
    await EpubDocumentCache.load(view);
    expect(calls, 2);
  });

  test('counts text and image backing buffers in oversized results', () async {
    final image = Uint8List.sublistView(Uint8List(3000), 0, 1);
    for (final document in [
      _document(text: List.filled(1500, 'x').join()),
      _document(image: image),
    ]) {
      var calls = 0;
      EpubDocumentCache.resetForTesting(
        maxEstimatedBytes: 2000,
        parser: (_) async {
          calls++;
          return document;
        },
      );
      final bytes = _bytes();
      await EpubDocumentCache.load(bytes);
      await EpubDocumentCache.load(bytes);
      expect(calls, 2);
    }
  });

  test('oversized results do not flush other cached documents', () async {
    var calls = 0;
    EpubDocumentCache.resetForTesting(
      maxEstimatedBytes: 1500,
      parser: (bytes) async {
        calls++;
        return _document(image: bytes.last == 2 ? Uint8List(2000) : null);
      },
    );
    final a = _bytes(1), b = _bytes(2);
    final first = await EpubDocumentCache.load(a);
    await EpubDocumentCache.load(b);
    expect(await EpubDocumentCache.load(a), same(first));
    await EpubDocumentCache.load(b);
    expect(calls, 3);
  });

  test('removes asynchronous rejections before retry', () async {
    var calls = 0;
    final document = _document();
    EpubDocumentCache.resetForTesting(
      parser: (_) async {
        if (++calls == 1) throw const FormatException('Try again');
        return document;
      },
    );
    final bytes = _bytes();
    final failed = EpubDocumentCache.load(bytes);
    await expectLater(failed, throwsFormatException);
    final retry = EpubDocumentCache.load(bytes);
    expect(retry, isNot(same(failed)));
    expect(await retry, same(document));
    expect(calls, 2);
  });

  test(
    'a rejection releases admission and does not strand queued loads',
    () async {
      final gate = Completer<EpubDocument>();
      var calls = 0;
      EpubDocumentCache.resetForTesting(
        maxPending: 2,
        parser: (_) => ++calls == 1 ? gate.future : Future.value(_document()),
      );
      final a = _bytes(1), b = _bytes(2);
      final failed = EpubDocumentCache.load(a);
      final failure = expectLater(failed, throwsFormatException);
      final queued = EpubDocumentCache.load(b);
      gate.completeError(const FormatException('Invalid'));
      await failure;
      await queued;
      expect(await EpubDocumentCache.load(a), isA<EpubDocument>());
      expect(calls, 3);
    },
  );

  test(
    'warm consumes sync, async and validation errors without unhandled errors',
    () async {
      final bytes = _bytes();
      EpubDocumentCache.resetForTesting(
        parser: (_) => throw const FormatException('Synchronous'),
      );
      // flutter_test fails the test for any unhandled zone error.
      unawaited(EpubDocumentCache.warm(bytes));
      await Future<void>.delayed(Duration.zero);
      EpubDocumentCache.resetForTesting(
        parser: (_) async => throw const FormatException('Asynchronous'),
      );
      unawaited(EpubDocumentCache.warm(bytes));
      unawaited(EpubDocumentCache.warm(Uint8List(0)));
      await Future<void>.delayed(Duration.zero);
      EpubDocumentCache.resetForTesting(parser: (_) async => _document());
      expect(await EpubDocumentCache.load(bytes), isA<EpubDocument>());
    },
  );

  test(
    'snapshots mutable inputs before queueing; never caches their identity',
    () async {
      final gate = Completer<EpubDocument>();
      final observed = <int>[];
      EpubDocumentCache.resetForTesting(
        parser: (bytes) async {
          if (bytes.last == 0) return gate.future;
          observed.add(bytes.last);
          expect(() => bytes[0] = 0, throwsUnsupportedError);
          return _document();
        },
      );
      final active = EpubDocumentCache.load(_bytes());
      final mutable = Uint8List.fromList(_bytes(1));
      final queued = EpubDocumentCache.load(mutable);
      mutable.last = 2;
      final next = EpubDocumentCache.load(mutable);
      expect(next, isNot(same(queued)));
      gate.complete(_document());
      await Future.wait([active, queued, next]);
      await EpubDocumentCache.load(mutable);
      expect(observed, [1, 2, 2]);
    },
  );

  test(
    'admits one active parse with a bounded queue; rejection can retry',
    () async {
      final gate = Completer<EpubDocument>();
      final observed = <int>[];
      EpubDocumentCache.resetForTesting(
        maxPending: 2,
        parser: (bytes) async {
          observed.add(bytes.last);
          return bytes.last == 1 ? gate.future : _document();
        },
      );
      final a = _bytes(1), b = _bytes(2), c = _bytes(3);
      final active = EpubDocumentCache.load(a);
      final queued = EpubDocumentCache.load(b);
      expect(EpubDocumentCache.load(a), same(active));
      expect(EpubDocumentCache.load(b), same(queued));
      await expectLater(EpubDocumentCache.load(c), throwsStateError);
      await EpubDocumentCache.warm(c);
      expect(observed, [1]);
      gate.complete(_document());
      await Future.wait([active, queued]);
      await EpubDocumentCache.load(c);
      expect(observed, [1, 2, 3]);
    },
  );

  test(
    'bounds pending source memory including a view backing buffer',
    () async {
      final gate = Completer<EpubDocument>();
      EpubDocumentCache.resetForTesting(
        maxPendingBytes: 9,
        parser: (_) => gate.future,
      );
      final bytes = _bytes();
      final active = EpubDocumentCache.load(bytes);
      await expectLater(EpubDocumentCache.load(_bytes(1)), throwsStateError);
      final backing = Uint8List(20)..setAll(0, _bytes(2));
      final view = Uint8List.sublistView(backing, 0, 5).asUnmodifiableView();
      await expectLater(EpubDocumentCache.load(view), throwsStateError);
      expect(EpubDocumentCache.load(bytes), same(active));
      gate.complete(_document());
      await active;
      await expectLater(EpubDocumentCache.load(view), throwsStateError);
    },
  );

  test(
    'remember skips mutable buffers and keeps a concurrent parse authoritative',
    () async {
      final gate = Completer<EpubDocument>();
      EpubDocumentCache.resetForTesting(parser: (_) => gate.future);
      final imported = _document(text: 'Imported');
      final bytes = _bytes();
      EpubDocumentCache.remember(bytes, imported);
      expect(await EpubDocumentCache.load(bytes), same(imported));
      final mutable = Uint8List.fromList(_bytes(1));
      EpubDocumentCache.remember(mutable, imported);
      final active = EpubDocumentCache.load(mutable);
      final other = _bytes(2);
      final queued = EpubDocumentCache.load(other);
      EpubDocumentCache.remember(other, imported);
      final parsed = _document(text: 'Parsed');
      gate.complete(parsed);
      expect(await active, same(parsed));
      expect(await queued, same(parsed));
      expect(await EpubDocumentCache.load(other), same(parsed));
    },
  );

  test('rejects invalid or oversized bytes before invoking a parser', () async {
    var calls = 0;
    EpubDocumentCache.resetForTesting(
      parser: (_) async {
        calls++;
        return _document();
      },
    );
    for (final bytes in [Uint8List(0), Uint8List(maxBookBytes + 1)]) {
      await expectLater(EpubDocumentCache.load(bytes), throwsFormatException);
      await EpubDocumentCache.warm(bytes);
    }
    expect(calls, 0);
  });

  test(
    'real parser prepares immutable resources, shares result and retries corrupt ZIP',
    () async {
      final bytes = _fixtureWithImages();
      await EpubDocumentCache.warm(bytes);
      final document = await EpubDocumentCache.load(bytes);
      expect(document.title, 'Uma hist\u00f3ria');
      final image = document.sections.first.blocks.last.image!;
      expect(document.cover, same(image));
      expect(image, [1, 2, 3, 4]);
      expect(() => image[0] = 0, throwsUnsupportedError);
      expect(
        () => document.cover!.buffer.asUint8List()[0] = 0,
        throwsUnsupportedError,
      );
      expect(await EpubDocumentCache.load(bytes), same(document));
      final corrupt = _bytes();
      final first = EpubDocumentCache.load(corrupt);
      await expectLater(first, throwsFormatException);
      final retry = EpubDocumentCache.load(corrupt);
      expect(retry, isNot(same(first)));
      await expectLater(retry, throwsFormatException);
    },
  );

  test(
    'direct parse also snapshots mutable bytes before asynchronous work',
    () async {
      final bytes = fixtureEpub();
      final document = EpubDocument.parse(bytes);
      bytes.fillRange(0, bytes.length, 0);
      expect((await document).sections, hasLength(2));
    },
  );

  test('prepares entry and spine batches with web macrotask yields', () async {
    // Enough work to cross the 4 ms budget, without wall-clock assertions.
    final bytes = _fixtureWithImages(batched: true);
    var ticks = 0;
    final timer = Timer.periodic(Duration.zero, (_) => ticks++);
    try {
      final document = await EpubDocumentCache.load(bytes);
      expect(document.sections, hasLength(31));
      expect(document.sections.first.title, 'First');
      expect(document.sections[29].blocks.last.image, same(document.cover));
      if (kIsWeb) expect(ticks, greaterThan(1));
    } finally {
      timer.cancel();
    }
  });
}
