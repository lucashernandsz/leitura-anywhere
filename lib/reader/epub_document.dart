import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:epubx/epubx.dart';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import '../data/book.dart';

const int maxEpubExpandedBytes = 120 * 1024 * 1024;
const int maxEpubEntries = 3000;

class EpubBlock {
  final String text;
  final int headingLevel;
  final Uint8List? image;

  const EpubBlock({required this.text, this.headingLevel = 0, this.image});
}

class EpubSection {
  final String title;
  final List<EpubBlock> blocks;

  EpubSection({required this.title, required List<EpubBlock> blocks})
    : blocks = List.unmodifiable(blocks);
}

class EpubDocument {
  final String title;
  final String author;
  final Uint8List? cover;
  final List<EpubSection> sections;

  EpubDocument({
    required this.title,
    required this.author,
    this.cover,
    required List<EpubSection> sections,
  }) : sections = List.unmodifiable(sections);

  static Future<EpubDocument> parse(Uint8List bytes) async {
    // Reject oversized input before compute copies it into another isolate.
    validateBookBytes(bytes);
    // Web parsing yields to the event loop. Own mutable input before any await;
    // read-only callers must supply an owned snapshot, as LocalBook does.
    final source = identical(bytes, bytes.asUnmodifiableView())
        ? bytes
        : Uint8List.fromList(bytes).asUnmodifiableView();
    return compute(_parseEpub, source, debugLabel: 'EPUB offline');
  }
}

/// Inspect the central directory before any inflater or EPUB reader runs.
/// ZIP64, split archives, encryption and ambiguous paths are not supported.
Future<
  Map<String, ({int size, int offset, int compressed, int method, int crc})>
>
_checkZip(Uint8List bytes, Stopwatch budget) async {
  final data = ByteData.sublistView(bytes);
  int u16(int offset) => data.getUint16(offset, Endian.little);
  int u32(int offset) => data.getUint32(offset, Endian.little);
  Never invalid() =>
      throw const FormatException('Arquivo ZIP inválido ou não suportado.');
  void checkExtra(int offset, int length) {
    final end = offset + length;
    while (offset < end) {
      if (offset + 4 > end) invalid();
      final id = u16(offset);
      final size = u16(offset + 2);
      if (id == 1 || id == 0x9901 || offset + 4 + size > end) invalid();
      offset += 4 + size;
    }
  }

  var end = -1;
  final lower = (bytes.length - 65557).clamp(0, bytes.length);
  for (var i = bytes.length - 22; i >= lower; i--) {
    if (u32(i) == 0x06054b50 && i + 22 + u16(i + 20) == bytes.length) {
      end = i;
      break;
    }
  }
  if (end < 0 || u16(end + 4) != 0 || u16(end + 6) != 0) invalid();
  final count = u16(end + 10);
  if (count > maxEpubEntries) {
    throw const FormatException('O EPUB excede o limite de 3000 entradas ZIP.');
  }
  final start = u32(end + 16);
  final length = u32(end + 12);
  if (count == 0 || u16(end + 8) != count || start + length != end) invalid();
  final sizes =
      <String, ({int size, int offset, int compressed, int method, int crc})>{};
  var cursor = start;
  var total = 0;
  final ranges = <(int, int)>[];
  for (var i = 0; i < count; i++) {
    if (kIsWeb && budget.elapsedMicroseconds >= 4000) {
      await Future<void>.delayed(Duration.zero);
      budget.reset();
    }
    if (cursor + 46 > end || u32(cursor) != 0x02014b50) invalid();
    final flags = u16(cursor + 8);
    final method = u16(cursor + 10);
    final compressed = u32(cursor + 20);
    final expanded = u32(cursor + 24);
    final nameLength = u16(cursor + 28);
    final entryLength = 46 + nameLength + u16(cursor + 30) + u16(cursor + 32);
    final local = u32(cursor + 42);
    total += expanded;
    if (total > maxEpubExpandedBytes) {
      throw const FormatException(
        'O EPUB excede o limite expandido de 120 MiB.',
      );
    }
    if (cursor + entryLength > end ||
        nameLength == 0 ||
        (flags & 0x41) != 0 ||
        (method != 0 && method != 8) ||
        compressed == 0xffffffff ||
        u16(cursor + 34) != 0 ||
        ((u32(cursor + 38) >> 16) & 0xf000) == 0xa000 ||
        local + 30 > start ||
        u32(local) != 0x04034b50 ||
        u16(local + 6) != flags ||
        u16(local + 8) != method ||
        u16(local + 26) != nameLength) {
      invalid();
    }
    final nameBytes = bytes.sublist(cursor + 46, cursor + 46 + nameLength);
    final name = utf8.decode(nameBytes);
    if (!_safeEntryName(name) || sizes.containsKey(name)) invalid();
    final payload = local + 30 + nameLength + u16(local + 28);
    if (payload + compressed > start) invalid();
    checkExtra(cursor + 46 + nameLength, u16(cursor + 30));
    checkExtra(local + 30 + nameLength, u16(local + 28));
    for (var j = 0; j < nameLength; j++) {
      if (bytes[local + 30 + j] != nameBytes[j]) invalid();
    }
    var payloadEnd = payload + compressed;
    if ((flags & 8) != 0) {
      if (payloadEnd + 12 > start) invalid();
      final descriptor = u32(payloadEnd) == 0x08074b50
          ? payloadEnd + 4
          : payloadEnd;
      if (descriptor + 12 > start ||
          u32(descriptor) != u32(cursor + 16) ||
          u32(descriptor + 4) != compressed ||
          u32(descriptor + 8) != expanded) {
        invalid();
      }
      payloadEnd = descriptor + 12;
    } else if (u32(local + 14) != u32(cursor + 16) ||
        u32(local + 18) != compressed ||
        u32(local + 22) != expanded) {
      invalid();
    }
    if (method == 0 && compressed != expanded) invalid();
    ranges.add((local, payloadEnd));
    sizes[name] = (
      size: expanded,
      offset: payload,
      compressed: compressed,
      method: method,
      crc: u32(cursor + 16),
    );
    cursor += entryLength;
  }
  if (cursor != end) invalid();
  ranges.sort((a, b) => a.$1.compareTo(b.$1));
  for (var i = 1; i < ranges.length; i++) {
    if (ranges[i].$1 < ranges[i - 1].$2) invalid();
  }
  return sizes;
}

// A dishonest central size must not let the inflater grow an unlimited buffer.
// Inflate.stream writes through this output instead of using native inflate.
class _LimitedOutput extends OutputStream {
  final int limit;
  bool exceeded = false;

  _LimitedOutput(this.limit) : super(size: limit.clamp(1, 32768).toInt());

  void _check(int count) {
    if (count < 0 || length + count > limit) {
      exceeded = true;
      throw const FormatException('Tamanho expandido do ZIP inconsistente.');
    }
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, [int? len]) {
    _check(len ?? bytes.length);
    super.writeBytes(bytes, len);
  }

  @override
  void writeInputStream(InputStreamBase stream) {
    _check(stream.length);
    super.writeInputStream(stream);
  }
}

bool _safeEntryName(String name) =>
    !name.startsWith('/') &&
    !name.contains('//') &&
    !name.contains(RegExp(r'[\\:\x00-\x1f]')) &&
    !name.split('/').any((part) => part == '..' || part == '.');

// Resolve EPUB references only inside the archive. Never fetch a URL, data URI,
// stylesheet or script. References escaping the archive and remote URLs fail.
String? _localPath(String base, String reference) {
  try {
    final uri = Uri.parse(reference.trim());
    if (uri.hasScheme || uri.hasAuthority || uri.path.startsWith('/')) {
      return null;
    }
    final decoded = Uri.decodeComponent(uri.path);
    if (decoded.isEmpty || decoded.contains(RegExp(r'[\\:\x00-\x1f]'))) {
      return null;
    }
    final parts = base.split('/')..removeLast();
    for (final part in decoded.split('/')) {
      if (part == '..') {
        if (parts.isEmpty) return null;
        parts.removeLast();
      } else if (part.isNotEmpty && part != '.') {
        parts.add(part);
      }
    }
    return parts.join('/');
  } on FormatException {
    return null;
  }
}

Future<EpubDocument> _parseEpub(Uint8List bytes) async {
  try {
    final budget = Stopwatch()..start();
    final sizes = await _checkZip(bytes, budget);
    // Retain bounded, CRC-checked bytes instead of inflating every entry again
    // when building the local resource map. Validate unused entries too.
    final validated = <String, Uint8List>{};
    for (final item in sizes.entries) {
      if (kIsWeb && budget.elapsedMicroseconds >= 4000) {
        await Future<void>.delayed(Duration.zero);
        budget.reset();
      }
      final entry = item.value;
      final raw = Uint8List.sublistView(
        bytes,
        entry.offset,
        entry.offset + entry.compressed,
      );
      List<int> expanded = raw;
      if (entry.method == 8) {
        final output = _LimitedOutput(entry.size);
        Inflate.stream(InputStream(raw), output);
        if (output.exceeded) {
          throw const FormatException(
            'Tamanho expandido do ZIP inconsistente.',
          );
        }
        expanded = output.getBytes();
      }
      if (expanded.length != entry.size || getCrc32(expanded) != entry.crc) {
        throw const FormatException(
          'Tamanho ou integridade do ZIP inconsistente.',
        );
      }
      validated[item.key] = Uint8List.fromList(expanded).asUnmodifiableView();
    }
    // Decode metadata only to preserve archive's file/directory classification.
    // Accessing file.content here would repeat inflation and CRC work.
    final archive = ZipDecoder().decodeBytes(bytes);
    final files = <String, Uint8List>{};
    for (final file in archive.files) {
      if (kIsWeb && budget.elapsedMicroseconds >= 4000) {
        await Future<void>.delayed(Duration.zero);
        budget.reset();
      }
      if (!file.isFile) continue;
      final content = validated[file.name];
      if (content == null || content.length != sizes[file.name]?.size) {
        throw const FormatException('Tamanho expandido do ZIP inconsistente.');
      }
      files[file.name] = content;
    }
    if (utf8.decode(files['mimetype'] ?? []) != 'application/epub+zip' ||
        !files.containsKey('META-INF/container.xml')) {
      throw const FormatException(
        'O arquivo não contém a estrutura de um EPUB.',
      );
    }
    final container = html.parse(utf8.decode(files['META-INF/container.xml']!));
    final root = container.querySelector('rootfile');
    final packagePath = _localPath('', root?.attributes['full-path'] ?? '');
    if (packagePath == null || !files.containsKey(packagePath)) {
      throw const FormatException('Pacote principal do EPUB não encontrado.');
    }

    // openBook reads schema/content references, not CoverImage. readBook would
    // unnecessarily decode and re-encode cover pixels through epubx's image API.
    if (kIsWeb && budget.elapsedMicroseconds >= 4000) {
      await Future<void>.delayed(Duration.zero);
      budget.reset();
    }
    final book = await EpubReader.openBook(bytes);
    final manifest = book.Schema?.Package?.Manifest?.Items;
    final spine = book.Schema?.Package?.Spine?.Items;
    if (manifest == null || spine == null || spine.isEmpty) {
      throw const FormatException(
        'O EPUB não contém uma sequência de leitura.',
      );
    }
    final sections = <EpubSection>[];
    for (final item in spine) {
      // A macrotask (not a microtask) lets browser input/painting run between
      // batches. Inflate, epubx metadata and a single HTML parse remain atomic.
      if (kIsWeb && budget.elapsedMicroseconds >= 4000) {
        await Future<void>.delayed(Duration.zero);
        budget.reset();
      }
      final matches = manifest.where((entry) => entry.Id == item.IdRef);
      if (matches.length != 1) {
        throw const FormatException(
          'Referência inválida na sequência do EPUB.',
        );
      }
      final entry = matches.single;
      final href = entry.Href;
      if (href == null) {
        throw const FormatException('Capítulo sem endereço local.');
      }
      final content = book.Content?.Html?[href];
      if (content == null) {
        // Non-HTML spine entries (for example SVG) are not renderable here.
        if (entry.MediaType == 'application/xhtml+xml' ||
            entry.MediaType == 'text/html') {
          throw const FormatException('Conteúdo de capítulo ausente no EPUB.');
        }
        continue;
      }
      final path = _localPath(packagePath, href);
      if (path == null || !files.containsKey(path)) {
        throw const FormatException('Capítulo fora do arquivo EPUB.');
      }
      // These bytes have already passed the bounded inflater and CRC check.
      // Do not inflate/copy every chapter a second time through epubx.
      final markup = utf8.decode(files[path]!);
      final section = _parseSection(markup, path, files, sections.length + 1);
      if (section.blocks.isNotEmpty) sections.add(section);
    }
    if (sections.isEmpty) {
      throw const FormatException(
        'O EPUB não contém texto ou imagens locais para leitura.',
      );
    }

    final package = html.parse(utf8.decode(files[packagePath]!));
    final coverId = package
        .querySelector('meta[name="cover"]')
        ?.attributes['content'];
    Uint8List? cover;
    for (final item in manifest) {
      if ((coverId != null && item.Id == coverId) ||
          (item.Properties ?? '')
              .split(RegExp(r'\s+'))
              .contains('cover-image')) {
        final path = _localPath(packagePath, item.Href ?? '');
        if (path != null && (item.MediaType ?? '').startsWith('image/')) {
          cover = files[path];
          if (cover != null) break;
        }
      }
    }
    return EpubDocument(
      title: _metadata(book.Title, 'Livro sem título'),
      author: _metadata(book.Author, 'Autor desconhecido'),
      cover: cover,
      sections: sections,
    );
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException(
      'Não foi possível abrir este EPUB. O arquivo pode estar corrompido ou protegido.',
    );
  }
}

String _metadata(String? value, String fallback) =>
    value == null || value.trim().isEmpty ? fallback : value.trim();

EpubSection _parseSection(
  String markup,
  String path,
  Map<String, Uint8List> files,
  int number,
) {
  final document = html.parse(markup);
  final documentTitle = document.querySelector('title')?.text.trim() ?? '';
  for (final node in document.querySelectorAll(
    'script, style, iframe, object, nav, form, embed, link, meta, noscript, template, head',
  )) {
    node.remove();
  }
  final blocks = <EpubBlock>[];
  var buffer = StringBuffer();
  var currentLevel = 0;
  var preserveSpace = false;
  void flush() {
    final raw = buffer.toString();
    final text = (preserveSpace ? raw : raw.replaceAll(RegExp(r'\s+'), ' '))
        .trim();
    if (text.isNotEmpty) {
      blocks.add(EpubBlock(text: text, headingLevel: currentLevel));
    }
    buffer = StringBuffer();
  }

  const boundaries = {
    'p',
    'li',
    'blockquote',
    'pre',
    'div',
    'section',
    'article',
    'header',
    'footer',
    'main',
    'aside',
    'figure',
    'figcaption',
    'ul',
    'ol',
    'table',
    'tr',
    'td',
    'th',
    'hr',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
  };
  void visit(dom.Node node, int level, bool pre) {
    if (node is dom.Text) {
      if (buffer.isEmpty) {
        currentLevel = level;
        preserveSpace = pre;
      }
      buffer.write(node.text);
      return;
    }
    if (node is! dom.Element) return;
    final tag = node.localName;
    if (tag == 'img' || tag == 'image') {
      flush();
      final source =
          node.attributes['src'] ??
          node.attributes['href'] ??
          node.attributes['xlink:href'] ??
          '';
      final imagePath = _localPath(path, source);
      final image = imagePath == null ? null : files[imagePath];
      final alt =
          (node.attributes['alt'] ?? node.attributes['aria-label'] ?? '')
              .trim();
      if (image != null || alt.isNotEmpty) {
        blocks.add(
          EpubBlock(text: alt.isEmpty ? 'Imagem do livro' : alt, image: image),
        );
      }
      return;
    }
    if (tag == 'br') {
      buffer.write('\n');
      return;
    }
    final boundary = boundaries.contains(tag);
    if (boundary) flush();
    final nextLevel = RegExp(r'^h[1-6]$').hasMatch(tag ?? '')
        ? int.parse(tag!.substring(1))
        : level;
    for (final child in node.nodes) {
      visit(child, nextLevel, pre || tag == 'pre');
    }
    if (boundary) flush();
  }

  final body = document.body;
  if (body != null) visit(body, 0, false);
  flush();
  final headings = blocks.where((block) => block.headingLevel > 0);
  final title = headings.isNotEmpty
      ? headings.first.text
      : (documentTitle.isNotEmpty ? documentTitle : 'Seção $number');
  return EpubSection(title: title, blocks: blocks);
}
