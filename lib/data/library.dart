import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import 'book.dart';

export 'book.dart' show LocalBook;

class LibraryException implements Exception {
  final String message;
  const LibraryException(this.message);

  @override
  String toString() => message;
}

class Library extends ChangeNotifier {
  static const _groupsKey = '@groups';
  final Box<dynamic> _box;
  Map<String, LocalBook> _books = {};
  List<List<String>> _groups = [];
  Future<void> _pending = Future<void>.value();
  bool _loaded = false;

  Library(Box<dynamic> box) : _box = box;

  List<LocalBook> get books {
    final sorted = _books.values.toList()
      ..sort((a, b) {
        final date = b.addedAt.compareTo(a.addedAt);
        return date != 0 ? date : a.book.id.compareTo(b.book.id);
      });
    return List<LocalBook>.unmodifiable(sorted);
  }

  LocalBook? find(String id) => _books[id];

  List<LocalBook> groupFor(String bookId) {
    final local = _books[bookId];
    if (local == null) return const <LocalBook>[];
    for (final group in _groups) {
      if (group.contains(bookId)) {
        return List<LocalBook>.unmodifiable(
          group.where(_books.containsKey).map((id) => _books[id]!),
        );
      }
    }
    return List<LocalBook>.unmodifiable([local]);
  }

  // Serialize read-modify-write operations; a failed write never poisons the queue.
  Future<void> _run(Future<void> Function() operation) {
    final result = _pending.then((_) async {
      try {
        await operation();
      } on LibraryException {
        rethrow;
      } on FormatException catch (error) {
        throw LibraryException(error.message);
      } catch (_) {
        throw const LibraryException(
          'Falha ao acessar a biblioteca. Os dados nao foram apagados.',
        );
      }
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  void _readBox() {
    final restored = <String, LocalBook>{};
    for (final key in _box.keys.toList()) {
      if (key == _groupsKey) continue;
      if (key is String && key.startsWith('@state/')) continue;
      try {
        final record = _box.get(key);
        if (key is! String ||
            record is! Map ||
            record['metadata'] is! Map ||
            record['bytes'] is! Uint8List ||
            (record['coverBytes'] != null &&
                record['coverBytes'] is! Uint8List)) {
          throw const FormatException('Registro binario invalido.');
        }
        final local = LocalBook.fromJson(
          Map<String, dynamic>.from(record['metadata'] as Map),
          bytes: record['bytes'] as Uint8List,
          coverBytes: record['coverBytes'] as Uint8List?,
        );
        if (local.book.id != key) {
          throw const FormatException('ID diverge da chave de armazenamento.');
        }
        final state = _box.get('@state/$key');
        if (state != null &&
            (state is! Map ||
                state['section'] is! int ||
                state['scroll'] is! num ||
                (state['textOffset'] != null && state['textOffset'] is! int) ||
                (state['progress'] != null && state['progress'] is! num) ||
                state['onDesk'] is! bool)) {
          throw const FormatException('Posicao de leitura corrompida.');
        }
        restored[key] = state == null
            ? local
            : local.copyWith(
                section: state['section'] as int,
                scroll: (state['scroll'] as num).toDouble(),
                textOffset: state['textOffset'] as int?,
                progress: (state['progress'] as num?)?.toDouble(),
                onDesk: state['onDesk'] as bool,
              );
      } catch (_) {
        throw LibraryException(
          'Entrada corrompida na biblioteca (chave: $key). '
          'Os dados e a biblioteca carregada foram preservados.',
        );
      }
    }
    final restoredGroups = <List<String>>[];
    try {
      if (_box.containsKey(_groupsKey)) {
        final record = _box.get(_groupsKey);
        if (record is! List) {
          throw const FormatException('Registro de grupos invalido.');
        }
        final seen = <String>{};
        for (final group in record) {
          if (group is! List || group.length < 2) {
            throw const FormatException('Grupo invalido.');
          }
          final members = <String>[];
          for (final id in group) {
            if (id is! String || id.trim().isEmpty || !seen.add(id)) {
              throw const FormatException('Membro de grupo invalido.');
            }
            if (restored.containsKey(id)) members.add(id);
          }
          // Stale references are ignored, never silently rewritten on disk.
          if (members.length >= 2) restoredGroups.add(members);
        }
      }
    } catch (_) {
      throw const LibraryException(
        'Entrada corrompida na biblioteca (chave: @groups). '
        'Os dados e a biblioteca carregada foram preservados.',
      );
    }
    // Replace the snapshot only when every entry validates successfully.
    _books = restored;
    _groups = restoredGroups;
    _loaded = true;
  }

  Future<void> load() => _run(() async {
    _readBox();
    notifyListeners();
  });

  Future<void> _save(LocalBook local, {bool content = false}) async {
    if (content) {
      await _box.put(local.book.id, {
        'metadata': local.toJson(),
        'bytes': local.bytes,
        'coverBytes': local.coverBytes,
      });
    } else {
      // Scrolling must not rewrite a potentially 40 MiB EPUB on every checkpoint.
      await _box.put('@state/${local.book.id}', {
        'section': local.section,
        'scroll': local.scroll,
        'textOffset': local.textOffset,
        'progress': local.progress,
        'onDesk': local.onDesk,
      });
    }
    _books[local.book.id] = local;
    notifyListeners();
  }

  Future<void> add(Book book, Uint8List bytes, {Uint8List? coverBytes}) async {
    // Snapshot caller-owned buffers before the asynchronous write is queued.
    final local = LocalBook(book: book, bytes: bytes, coverBytes: coverBytes);
    await _run(() async {
      if (!_loaded) _readBox();
      if (book.id == _groupsKey) {
        throw const LibraryException('ID reservado da biblioteca: @groups.');
      }
      Book.fromJson(book.toJson());
      final previous = _books[book.id];
      await _save(
        previous == null
            ? local
            : LocalBook(
                book: book,
                bytes: local.bytes,
                coverBytes: local.coverBytes ?? previous.coverBytes,
                section: previous.section,
                scroll: previous.scroll,
                textOffset: previous.textOffset,
                progress: previous.progress,
                onDesk: previous.onDesk,
                addedAt: previous.addedAt,
              ),
        content: true,
      );
    });
  }

  Future<void> updatePosition(
    String id,
    int section,
    double scroll, {
    int? textOffset,
    double? progress,
  }) => _run(() async {
    if (!_loaded) _readBox();
    final local = _books[id];
    if (local == null) throw LibraryException('Livro nao encontrado: $id.');
    await _save(
      local.copyWith(
        section: section,
        scroll: scroll,
        textOffset: textOffset,
        progress: progress,
      ),
    );
  });

  Future<void> setOnDesk(String id, bool value) => _run(() async {
    if (!_loaded) _readBox();
    final local = _books[id];
    if (local == null) throw LibraryException('Livro nao encontrado: $id.');
    await _save(local.copyWith(onDesk: value));
  });

  Future<void> _saveGroups(List<List<String>> groups) async {
    await _box.put(_groupsKey, groups);
    _groups = groups;
    notifyListeners();
  }

  Future<void> groupBooks(String bookId, String otherBookId) => _run(() async {
    if (!_loaded) _readBox();
    for (final id in [bookId, otherBookId]) {
      if (!_books.containsKey(id)) {
        throw LibraryException('Livro nao encontrado: $id.');
      }
    }
    if (bookId == otherBookId) {
      throw const LibraryException('Selecione dois livros distintos.');
    }
    final members = {
      ...groupFor(bookId).map((local) => local.book.id),
      ...groupFor(otherBookId).map((local) => local.book.id),
    };
    await _saveGroups([
      ..._groups.where(
        (group) => !group.contains(bookId) && !group.contains(otherBookId),
      ),
      members.toList(),
    ]);
  });

  Future<void> ungroupBook(String bookId) => _run(() async {
    if (!_loaded) _readBox();
    if (!_books.containsKey(bookId)) {
      throw LibraryException('Livro nao encontrado: $bookId.');
    }
    final groups = <List<String>>[];
    for (final group in _groups) {
      final members = group
          .where((id) => id != bookId && _books.containsKey(id))
          .toList();
      if (members.length >= 2) groups.add(members);
    }
    await _saveGroups(groups);
  });

  Future<void> remove(String id) => _run(() async {
    if (!_loaded) _readBox();
    if (id == _groupsKey) return;
    await _box.deleteAll([id, '@state/$id']);
    _books.remove(id);
    notifyListeners();
  });
}
