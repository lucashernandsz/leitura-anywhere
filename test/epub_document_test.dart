import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:leitura_anywhere/data/book.dart';
import 'package:leitura_anywhere/reader/epub_document.dart';

Uint8List _epub({
  String first = '<h1>Primeiro</h1><p>Texto um.</p>',
  String second = '<h1>Segundo</h1><p>Texto dois.</p>',
  String mimetype = 'application/epub+zip',
  bool container = true,
  bool cover = false,
  bool navigation = true,
  bool compress = true,
  Map<String, List<int>> extras = const {},
}) {
  final archive = Archive();
  void add(String name, List<int> bytes) {
    final file = ArchiveFile(name, bytes.length, bytes);
    if (name == 'mimetype' || !compress) file.compress = false;
    archive.addFile(file);
  }

  void text(String name, String value) => add(name, utf8.encode(value));
  text('mimetype', mimetype);
  if (container) {
    text('META-INF/container.xml', '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''');
  }
  text('OPS/book.opf', '''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="book-id">test:offline</dc:identifier>
    <dc:title>Livro offline</dc:title><dc:creator>Autora de teste</dc:creator>
    <dc:language>pt</dc:language>
    ${cover ? '<meta name="cover" content="cover"/>' : ''}
  </metadata>
  <manifest>
    <item id="second" href="Text/second.xhtml" media-type="application/xhtml+xml"/>
    <item id="first" href="Text/first.xhtml" media-type="application/xhtml+xml"/>
    <item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    ${cover ? '<item id="cover" href="Images/cover.jpg" media-type="image/jpeg"/>' : ''}
  </manifest>
  <spine toc="toc"><itemref idref="first"/><itemref idref="second"/></spine>
</package>''');
  text('OPS/toc.ncx', '''<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="test:offline"/></head>
  <docTitle><text>Livro offline</text></docTitle>
  <navMap>
    ${navigation ? '<navPoint id="first" playOrder="1"><navLabel><text>Primeiro</text></navLabel><content src="Text/first.xhtml"/></navPoint>' : ''}
    ${navigation ? '<navPoint id="second" playOrder="2"><navLabel><text>Segundo</text></navLabel><content src="Text/second.xhtml"/></navPoint>' : ''}
  </navMap>
</ncx>''');
  String page(String body) => '''<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Capítulo</title></head><body>$body</body></html>''';
  // Both ZIP insertion and manifest order deliberately oppose the spine.
  text('OPS/Text/second.xhtml', page(second));
  text('OPS/Text/first.xhtml', page(first));
  if (cover) add('OPS/Images/cover.jpg', [1, 2, 3, 4]);
  for (final entry in extras.entries) {
    add(entry.key, entry.value);
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

int _centralOffset(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  for (var i = bytes.length - 22; i >= 0; i--) {
    if (data.getUint32(i, Endian.little) == 0x06054b50) {
      return data.getUint32(i + 16, Endian.little);
    }
  }
  throw StateError('Synthetic ZIP has no central directory.');
}

void _advertiseSize(Uint8List bytes, String fileName, int size) {
  final data = ByteData.sublistView(bytes);
  var cursor = _centralOffset(bytes);
  while (data.getUint32(cursor, Endian.little) == 0x02014b50) {
    final nameLength = data.getUint16(cursor + 28, Endian.little);
    final name = utf8.decode(
      bytes.sublist(cursor + 46, cursor + 46 + nameLength),
    );
    if (name == fileName) {
      final local = data.getUint32(cursor + 42, Endian.little);
      data.setUint32(cursor + 24, size, Endian.little);
      data.setUint32(local + 22, size, Endian.little);
      if ((data.getUint16(cursor + 8, Endian.little) & 8) != 0) {
        var descriptor =
            local +
            30 +
            nameLength +
            data.getUint16(local + 28, Endian.little) +
            data.getUint32(cursor + 20, Endian.little);
        if (data.getUint32(descriptor, Endian.little) == 0x08074b50) {
          descriptor += 4;
        }
        data.setUint32(descriptor + 8, size, Endian.little);
      }
      return;
    }
    cursor +=
        46 +
        nameLength +
        data.getUint16(cursor + 30, Endian.little) +
        data.getUint16(cursor + 32, Endian.little);
  }
  throw StateError('Synthetic ZIP has no entry $fileName.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('uses spine order, not HTML map order, and extracts metadata', () async {
    final document = await EpubDocument.parse(_epub());
    expect(document.title, 'Livro offline');
    expect(document.author, 'Autora de teste');
    expect(document.sections.map((section) => section.title), [
      'Primeiro',
      'Segundo',
    ]);
    expect(document.sections.first.blocks.map((block) => block.text), [
      'Primeiro',
      'Texto um.',
    ]);
    expect(document.sections.first.blocks.first.headingLevel, 1);
    expect(document.sections.first.blocks.last.headingLevel, 0);
    expect(() => document.sections.clear(), throwsUnsupportedError);
    expect(
      () => document.sections.first.blocks.clear(),
      throwsUnsupportedError,
    );
  });

  test(
    'removes active HTML and keeps links as text without remote resources',
    () async {
      final document = await EpubDocument.parse(
        _epub(
          first: '''
<h2>Seguro</h2>
<script>SEGREDO_SCRIPT</script><style>SEGREDO_STYLE</style>
<iframe src="https://example.invalid/frame">SEGREDO_IFRAME</iframe>
<object data="https://example.invalid/object">SEGREDO_OBJECT</object>
<nav>SEGREDO_NAV</nav><form>SEGREDO_FORM</form>
<p>Leia <a href="https://example.invalid/link" onclick="SEGREDO_EVENTO">este link</a> aqui.</p>
<img src="https://example.invalid/remote.jpg" alt="Imagem remota não carregada"/>
<img src="//example.invalid/remote.jpg"/>
<img src="data:image/png;base64,AAAA"/>
<img src="../../../../escape.png"/>
<img src="../Images/local.png" alt="Ilustração local"/>
''',
          extras: {
            'OPS/Images/local.png': [4, 3, 2, 1],
          },
        ),
      );
      final blocks = document.sections.first.blocks;
      final text = blocks.map((block) => block.text).join('\n');
      expect(text, contains('Leia este link aqui.'));
      expect(text, isNot(contains('SEGREDO')));
      expect(text, isNot(contains('example.invalid')));
      expect(text, isNot(contains('base64')));
      final images = blocks.where((block) => block.image != null).toList();
      expect(images, hasLength(1));
      expect(images.single.text, 'Ilustração local');
      expect(images.single.image, [4, 3, 2, 1]);
    },
  );

  test(
    'preserves inline text once, list items, quotes and preformatted text',
    () async {
      final document = await EpubDocument.parse(
        _epub(
          first: '''
<div><p>Antes <strong>forte</strong> depois.</p>
<ul><li>Item um</li><li>Item <em>dois</em></li></ul>
<blockquote><p>Citação única.</p></blockquote>
<pre>linha 1
  linha 2</pre></div>''',
        ),
      );
      expect(document.sections.first.blocks.map((block) => block.text), [
        'Antes forte depois.',
        'Item um',
        'Item dois',
        'Citação única.',
        'linha 1\n  linha 2',
      ]);
    },
  );

  test(
    'takes cover bytes from metadata without decoding image pixels',
    () async {
      final document = await EpubDocument.parse(_epub(cover: true));
      // Deliberately not a JPEG: metadata extraction must not decode CoverImage.
      expect(document.cover, [1, 2, 3, 4]);
    },
  );

  test('reads spine content even when no chapter headings exist', () async {
    final document = await EpubDocument.parse(
      _epub(first: '<p>Sem título.</p>', navigation: false),
    );
    expect(document.sections.first.blocks.single.text, 'Sem título.');
  });

  test('reads stored entries and empty optional resources', () async {
    final document = await EpubDocument.parse(
      _epub(compress: false, cover: true, extras: {'OPS/empty.css': []}),
    );
    expect(document.title, 'Livro offline');
    expect(document.sections.map((section) => section.title), [
      'Primeiro',
      'Segundo',
    ]);
    expect(document.cover, [1, 2, 3, 4]);
  });

  test('rejects forged CRC even for unused entries', () async {
    final archive = ZipDecoder().decodeBytes(_epub());
    archive.addFile(
      ArchiveFile.noCompress('unused.bin', 4, Uint8List.fromList([1, 2, 3, 4]))
        ..crc32 = 0,
    );
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);
    await expectLater(
      EpubDocument.parse(bytes),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('integridade'),
        ),
      ),
    );
  });

  test(
    'rejects missing structure, fake mimetype, broken ZIP and empty books',
    () async {
      for (final bytes in [
        Uint8List(0),
        Uint8List.fromList([0x50, 0x4b, 0x03, 0x04]),
        _epub(container: false),
        _epub(mimetype: 'application/zip'),
        _epub(
          first: '<script>sem leitura</script>',
          second: '<nav>sem leitura</nav>',
        ),
      ]) {
        await expectLater(EpubDocument.parse(bytes), throwsFormatException);
      }
    },
  );

  test('rejects imports above 40 MiB before sending data to compute', () async {
    await expectLater(
      EpubDocument.parse(Uint8List(maxBookBytes + 1)),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('40 MiB'),
        ),
      ),
    );
  });

  test(
    'rejects expanded bombs from central sizes before decompression',
    () async {
      final bytes = _epub();
      final data = ByteData.sublistView(bytes);
      data.setUint32(
        _centralOffset(bytes) + 24,
        maxEpubExpandedBytes + 1,
        Endian.little,
      );
      // The central header advertises a bomb; no large payload is allocated.
      await expectLater(
        EpubDocument.parse(bytes),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('120 MiB'),
          ),
        ),
      );
    },
  );

  test('rejects archives advertising more than 3000 entries', () async {
    final bytes = _epub();
    final data = ByteData.sublistView(bytes);
    final end = bytes.length - 22;
    data.setUint16(end + 8, maxEpubEntries + 1, Endian.little);
    data.setUint16(end + 10, maxEpubEntries + 1, Endian.little);
    await expectLater(
      EpubDocument.parse(bytes),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('3000'),
        ),
      ),
    );
  });

  test(
    'bounds inflation even when both ZIP headers lie about expanded size',
    () async {
      final bytes = _epub(
        extras: {'padding.txt': List<int>.filled(1024 * 1024, 65)},
      );
      _advertiseSize(bytes, 'padding.txt', 1);
      await expectLater(EpubDocument.parse(bytes), throwsFormatException);
    },
  );

  test(
    'checks the total expanded size, not only individual ZIP entries',
    () async {
      final bytes = _epub(
        extras: {
          'padding-a.txt': List<int>.filled(1024, 65),
          'padding-b.txt': List<int>.filled(1024, 66),
        },
      );
      _advertiseSize(bytes, 'padding-a.txt', 61 * 1024 * 1024);
      _advertiseSize(bytes, 'padding-b.txt', 61 * 1024 * 1024);
      await expectLater(
        EpubDocument.parse(bytes),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('120 MiB'),
          ),
        ),
      );
    },
  );

  test('rejects traversal and inconsistent central sizes', () async {
    await expectLater(
      EpubDocument.parse(
        _epub(extras: {'../escape.txt': utf8.encode('escape')}),
      ),
      throwsFormatException,
    );
    final bytes = _epub();
    ByteData.sublistView(
      bytes,
    ).setUint32(_centralOffset(bytes) + 24, 1, Endian.little);
    await expectLater(EpubDocument.parse(bytes), throwsFormatException);
  });
}
