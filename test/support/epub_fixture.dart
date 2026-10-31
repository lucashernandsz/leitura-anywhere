import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

Uint8List fixtureEpub() {
  final archive = Archive();
  void add(String name, String content) {
    final bytes = utf8.encode(content);
    final file = ArchiveFile(name, bytes.length, bytes);
    if (name == 'mimetype') file.compress = false;
    archive.addFile(file);
  }

  add('mimetype', 'application/epub+zip');
  add(
    'META-INF/container.xml',
    '''<?xml version="1.0"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
<rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>''',
  );
  add(
    'book.opf',
    '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">fixture</dc:identifier>
<dc:title>Uma história</dc:title><dc:creator>Uma autora</dc:creator><dc:language>pt</dc:language></metadata>
<manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/>
<item id="two" href="two.xhtml" media-type="application/xhtml+xml"/>
<item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest>
<spine toc="toc"><itemref idref="one"/><itemref idref="two"/></spine></package>''',
  );
  add('toc.ncx', '''<?xml version="1.0"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="fixture"/></head>
<docTitle><text>Uma história</text></docTitle><navMap>
<navPoint id="one" playOrder="1"><navLabel><text>Começo</text></navLabel><content src="one.xhtml"/></navPoint>
<navPoint id="two" playOrder="2"><navLabel><text>Depois</text></navLabel><content src="two.xhtml"/></navPoint>
</navMap></ncx>''');
  add(
    'one.xhtml',
    '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Começo</title></head><body><h1>Começo</h1>${List.generate(12, (i) => '<p>Parágrafo $i. A leitura continua no silêncio de uma tarde.</p>').join()}</body></html>',
  );
  add(
    'two.xhtml',
    '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Depois</title></head><body><h1>Depois</h1><p>Uma nova seção para continuar a história.</p></body></html>',
  );
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}
