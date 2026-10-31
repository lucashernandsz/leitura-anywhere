import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../data/book.dart';
import 'epub_document.dart';

/// Process-local, identity-keyed cache for prepared EPUB documents.
///
/// Pass an owned, read-only snapshot (for example LocalBook.bytes) for O(1)
/// reuse and in-flight deduplication. A read-only view is NOT proof that its
/// backing storage has no writable aliases: callers must never mutate aliases.
/// Mutable inputs are copied synchronously, never keyed or retained for reuse.
/// Dart has no public isUnmodifiable flag; supported SDKs return the same object
/// from asUnmodifiableView for read-only lists. Otherwise caching is skipped.
///
/// Completed documents use LRU eviction: at most 3 documents and 64 MiB estimated
/// retained memory, including source buffers, UTF-16 text and encoded images.
/// This is not a heap limit (DOM, inflater, decoded pixels and caller references
/// are outside the cache). One parse runs at a time; at most 4 pending requests
/// and 80 MiB of pending source buffers are admitted. Excess loads fail with
/// StateError and can be retried; warm deliberately ignores these failures.
abstract final class EpubDocumentCache {
  static final _documents =
      LinkedHashMap<Uint8List, _CachedDocument>.identity();
  static final _pending = Map<Uint8List, _PendingDocument>.identity();
  static final _queue = ListQueue<_PendingDocument>();
  static var _parser = EpubDocument.parse;
  static var _maxDocuments = 3;
  static var _maxEstimatedBytes = 64 * 1024 * 1024;
  static var _maxPending = 4;
  static var _maxPendingBytes = 80 * 1024 * 1024;
  static var _retainedBytes = 0;
  static var _pendingBytes = 0;
  static var _pendingCount = 0;
  static var _running = false;

  static Future<EpubDocument> load(Uint8List bytes) {
    try {
      final cacheable = identical(bytes, bytes.asUnmodifiableView());
      if (cacheable) {
        final cached = _documents.remove(bytes);
        if (cached != null) {
          _documents[bytes] = cached;
          return cached.future;
        }
        final pending = _pending[bytes];
        if (pending != null) return pending.completer.future;
      }
      // Check before allocating a snapshot or admitting another parser job.
      validateBookBytes(bytes);
      final size = cacheable ? bytes.buffer.lengthInBytes : bytes.lengthInBytes;
      if (_pendingCount >= _maxPending ||
          _pendingBytes + size > _maxPendingBytes) {
        throw StateError('EPUB preparation queue is full; retry later.');
      }
      final source = cacheable
          ? bytes
          : Uint8List.fromList(bytes).asUnmodifiableView();
      final request = _PendingDocument(source, cacheable, size);
      if (cacheable) _pending[bytes] = request;
      _pendingCount++;
      _pendingBytes += size;
      _queue.add(request);
      if (!_running) unawaited(_drain());
      return request.completer.future;
    } catch (error, stack) {
      return Future<EpubDocument>.error(error, stack);
    }
  }

  /// Safe to call without awaiting: all preparation errors are consumed here.
  static Future<void> warm(Uint8List bytes) async {
    try {
      await load(bytes);
    } catch (_) {
      // Speculative preparation must not surface an unhandled asynchronous error.
    }
  }

  /// Remembers a document already validated by EpubDocument.parse for these exact
  /// bytes. Never use this to admit unvalidated content. Mutable inputs are
  /// ignored; an existing in-flight parse wins over an import result.
  static void remember(Uint8List bytes, EpubDocument document) {
    if (!identical(bytes, bytes.asUnmodifiableView())) return;
    validateBookBytes(bytes);
    if (_pending.containsKey(bytes)) return;
    _retain(bytes, document, Future<EpubDocument>.value(document));
  }

  static Future<void> _drain() async {
    _running = true;
    while (_queue.isNotEmpty) {
      final request = _queue.removeFirst();
      try {
        final document = await _parser(request.bytes);
        if (request.cacheable) {
          _retain(request.bytes, document, request.completer.future);
        }
        request.completer.complete(document);
      } catch (error, stack) {
        request.completer.completeError(error, stack);
      } finally {
        if (request.cacheable) _pending.remove(request.bytes);
        _pendingCount--;
        _pendingBytes -= request.size;
      }
    }
    _running = false;
  }

  static void _retain(
    Uint8List bytes,
    EpubDocument document,
    Future<EpubDocument> future,
  ) {
    // Count backing buffers, not just views. Different views may overcount a
    // shared buffer, but must never hide a much larger retained allocation.
    var size = bytes.buffer.lengthInBytes + 256;
    final images = Set<Uint8List>.identity();
    void image(Uint8List? value) {
      if (value != null && images.add(value)) {
        size += value.buffer.lengthInBytes + 64;
      }
    }

    size += 2 * (document.title.length + document.author.length);
    image(document.cover);
    for (final section in document.sections) {
      size += 128 + 2 * section.title.length;
      for (final block in section.blocks) {
        size += 96 + 2 * block.text.length;
        image(block.image);
      }
    }
    final previous = _documents.remove(bytes);
    if (previous != null) _retainedBytes -= previous.size;
    // A single oversized result is returned, not cached, without flushing others.
    if (_maxDocuments == 0 || size > _maxEstimatedBytes) return;
    while (_documents.isNotEmpty &&
        (_documents.length >= _maxDocuments ||
            _retainedBytes + size > _maxEstimatedBytes)) {
      _retainedBytes -= _documents.remove(_documents.keys.first)!.size;
    }
    _documents[bytes] = _CachedDocument(future, size);
    _retainedBytes += size;
  }

  /// Isolates tests without changing application defaults or bypassing admission.
  @visibleForTesting
  static void resetForTesting({
    Future<EpubDocument> Function(Uint8List) parser = EpubDocument.parse,
    int maxDocuments = 3,
    int maxEstimatedBytes = 64 * 1024 * 1024,
    int maxPending = 4,
    int maxPendingBytes = 80 * 1024 * 1024,
  }) {
    if (_running) throw StateError('Wait for pending EPUB preparations first.');
    if (maxDocuments < 0 ||
        maxEstimatedBytes < 0 ||
        maxPending < 1 ||
        maxPendingBytes < 1) {
      throw ArgumentError('Invalid EPUB cache limits.');
    }
    _documents.clear();
    _pending.clear();
    _queue.clear();
    _retainedBytes = _pendingBytes = _pendingCount = 0;
    _parser = parser;
    _maxDocuments = maxDocuments;
    _maxEstimatedBytes = maxEstimatedBytes;
    _maxPending = maxPending;
    _maxPendingBytes = maxPendingBytes;
  }
}

class _PendingDocument {
  final Uint8List bytes;
  final bool cacheable;
  final int size;
  final completer = Completer<EpubDocument>();

  _PendingDocument(this.bytes, this.cacheable, this.size);
}

class _CachedDocument {
  final Future<EpubDocument> future;
  final int size;

  _CachedDocument(this.future, this.size);
}
