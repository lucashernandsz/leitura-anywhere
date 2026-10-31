import 'package:flutter/foundation.dart';

import 'book.dart';
import 'catalog.dart';
import 'zlibrary_catalog.dart';

/// Source selection is session-only; downloaded books stay in the same library.
class CatalogSources extends ChangeNotifier implements BookCatalog {
  final BookCatalog primary;
  final ZLibraryCatalog zLibrary;
  bool _isZLibrary = false;
  int _selectionRevision = 0;
  bool _disposed = false;

  CatalogSources({required this.primary, required this.zLibrary}) {
    zLibrary.addListener(notifyListeners);
  }

  bool get isZLibrary => _isZLibrary;
  int get selectionRevision => _selectionRevision;
  BookCatalog get _active => _isZLibrary ? zLibrary : primary;

  void selectZLibrary(bool selected) {
    if (selected && !zLibrary.supported) {
      throw const ApiException(
        'Z-Library exige o servidor web local nesta etapa.',
      );
    }
    _selectionRevision++;
    if (_isZLibrary == selected) return;
    _isZLibrary = selected;
    notifyListeners();
  }

  Future<void> restoreSession({bool selectRestoredSource = true}) async {
    final revision = _selectionRevision;
    if (await zLibrary.restoreSession(renew: true) &&
        !_disposed &&
        selectRestoredSource &&
        revision == _selectionRevision) {
      selectZLibrary(true);
    }
  }

  @override
  String get displayName => _active.displayName;
  @override
  String get usageNotice => _active.usageNotice;
  @override
  Future<CatalogPage> search({
    String query = '',
    String? topic,
    int page = 1,
  }) => _active.search(query: query, topic: topic, page: page);
  @override
  Future<Uint8List> download(Book book, {void Function(double?)? onProgress}) =>
      _active.download(book, onProgress: onProgress);

  @override
  void dispose() {
    _disposed = true;
    zLibrary.removeListener(notifyListeners);
    primary.dispose();
    zLibrary.dispose();
    super.dispose();
  }
}
