import 'dart:typed_data';

const int maxBookBytes = 40 * 1024 * 1024;

/// Checks the size and local-file ZIP signature without executing EPUB content.
/// This is a transport check, not a complete EPUB/archive validation.
void validateBookBytes(Uint8List bytes) {
  if (bytes.length > maxBookBytes) {
    throw const FormatException('O EPUB excede o limite de 40 MiB.');
  }
  if (bytes.length < 4 ||
      bytes[0] != 0x50 ||
      bytes[1] != 0x4b ||
      bytes[2] != 0x03 ||
      bytes[3] != 0x04) {
    throw const FormatException('EPUB vazio ou sem assinatura ZIP valida.');
  }
}

bool isSecureBookUri(Uri uri) {
  return uri.scheme == 'https' &&
      uri.hasAuthority &&
      uri.host.isNotEmpty &&
      !RegExp(r'[\s\\]').hasMatch(uri.host) &&
      uri.userInfo.isEmpty &&
      uri.port > 0 &&
      uri.port <= 65535;
}

class Book {
  final String id;
  final String title;
  final String author;
  final String source;
  final String? coverUrl;
  final String? downloadUrl;
  final List<String> subjects;

  Book({
    required this.id,
    required this.title,
    required this.author,
    required this.source,
    this.coverUrl,
    this.downloadUrl,
    List<String> subjects = const [],
  }) : subjects = List<String>.unmodifiable(subjects);

  bool get downloadable {
    final uri = Uri.tryParse(downloadUrl ?? '');
    return uri != null && isSecureBookUri(uri);
  }

  factory Book.fromJson(Map<String, dynamic> json) {
    for (final key in ['id', 'title', 'author', 'source']) {
      if (json[key] is! String || (json[key] as String).trim().isEmpty) {
        throw FormatException('Metadado de livro invalido: $key.');
      }
    }
    for (final key in ['coverUrl', 'downloadUrl']) {
      if (json[key] != null && json[key] is! String) {
        throw FormatException('Metadado de livro invalido: $key.');
      }
    }
    final subjects = json['subjects'] ?? const <String>[];
    if (subjects is! List || subjects.any((value) => value is! String)) {
      throw const FormatException('Assuntos do livro invalidos.');
    }
    return Book(
      id: json['id'] as String,
      title: json['title'] as String,
      author: json['author'] as String,
      source: json['source'] as String,
      coverUrl: json['coverUrl'] as String?,
      downloadUrl: json['downloadUrl'] as String?,
      subjects: List<String>.from(subjects),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'source': source,
    'coverUrl': coverUrl,
    'downloadUrl': downloadUrl,
    'subjects': subjects.toList(),
  };
}

class LocalBook {
  final Book book;
  final Uint8List bytes;
  final Uint8List? coverBytes;
  final int section;
  final double scroll;

  /// UTF-16 offset within the section, independent of the reader viewport.
  final int? textOffset;
  final double? progress;
  final bool onDesk;
  final DateTime addedAt;

  LocalBook({
    required this.book,
    required Uint8List bytes,
    Uint8List? coverBytes,
    this.section = 0,
    this.scroll = 0,
    this.textOffset,
    this.progress,
    this.onDesk = true,
    DateTime? addedAt,
  }) : bytes = _snapshotBytes(bytes),
       coverBytes = coverBytes == null
           ? null
           : Uint8List.fromList(coverBytes).asUnmodifiableView(),
       addedAt = addedAt ?? DateTime.now().toUtc() {
    if (section < 0 ||
        !scroll.isFinite ||
        scroll < 0 ||
        (textOffset != null && textOffset! < 0) ||
        (progress != null &&
            (!progress!.isFinite || progress! < 0 || progress! > 1))) {
      throw const FormatException('Posicao de leitura invalida.');
    }
  }

  static Uint8List _snapshotBytes(Uint8List bytes) {
    // Reject oversized imports before allocating a second full book buffer.
    validateBookBytes(bytes);
    return Uint8List.fromList(bytes).asUnmodifiableView();
  }

  LocalBook._snapshot({
    required this.book,
    required this.bytes,
    required this.coverBytes,
    required this.section,
    required this.scroll,
    required this.textOffset,
    required this.progress,
    required this.onDesk,
    required this.addedAt,
  });

  LocalBook copyWith({
    int? section,
    double? scroll,
    int? textOffset,
    double? progress,
    bool? onDesk,
  }) {
    final nextSection = section ?? this.section;
    final nextScroll = scroll ?? this.scroll;
    final nextTextOffset = textOffset ?? this.textOffset;
    final nextProgress = progress ?? this.progress;
    if (nextSection < 0 ||
        !nextScroll.isFinite ||
        nextScroll < 0 ||
        (nextTextOffset != null && nextTextOffset < 0) ||
        (nextProgress != null &&
            (!nextProgress.isFinite || nextProgress < 0 || nextProgress > 1))) {
      throw const FormatException('Posicao de leitura invalida.');
    }
    return LocalBook._snapshot(
      book: book,
      bytes: bytes,
      coverBytes: coverBytes,
      section: nextSection,
      scroll: nextScroll,
      textOffset: nextTextOffset,
      progress: nextProgress,
      onDesk: onDesk ?? this.onDesk,
      addedAt: addedAt,
    );
  }

  /// Binary data is supplied separately from the Hive record, never JSON.
  factory LocalBook.fromJson(
    Map<String, dynamic> json, {
    required Uint8List bytes,
    Uint8List? coverBytes,
  }) {
    final book = json['book'];
    final section = json['section'];
    final scroll = json['scroll'];
    final textOffset = json['textOffset'];
    final progress = json['progress'];
    final onDesk = json['onDesk'];
    final addedAt = json['addedAt'];
    if (book is! Map ||
        section is! int ||
        scroll is! num ||
        (textOffset != null && textOffset is! int) ||
        (progress != null && progress is! num) ||
        onDesk is! bool ||
        addedAt is! String) {
      throw const FormatException('Metadados locais corrompidos.');
    }
    final date = DateTime.tryParse(addedAt);
    if (date == null) {
      throw const FormatException('Data de adicao invalida.');
    }
    return LocalBook(
      book: Book.fromJson(Map<String, dynamic>.from(book)),
      bytes: bytes,
      coverBytes: coverBytes,
      section: section,
      scroll: scroll.toDouble(),
      textOffset: textOffset as int?,
      progress: (progress as num?)?.toDouble(),
      onDesk: onDesk,
      addedAt: date,
    );
  }

  Map<String, dynamic> toJson() => {
    'book': book.toJson(),
    'section': section,
    'scroll': scroll,
    'textOffset': textOffset,
    'progress': progress,
    'onDesk': onDesk,
    'addedAt': addedAt.toUtc().toIso8601String(),
  };
}
