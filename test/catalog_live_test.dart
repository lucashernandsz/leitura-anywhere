import 'package:flutter_test/flutter_test.dart';
import 'package:leitura_anywhere/data/catalog.dart';
import 'package:leitura_anywhere/reader/epub_document.dart';

void main() {
  test(
    'live search, download and EPUB parsing',
    () async {
      final catalog = CatalogService();
      addTearDown(catalog.dispose);
      final page = await catalog.search(query: 'Machado');
      expect(page.books, isNotEmpty);
      final book = page.books.firstWhere((book) => book.downloadable);
      final document = await EpubDocument.parse(await catalog.download(book));
      expect(document.title, isNotEmpty);
      expect(document.sections, isNotEmpty);
    },
    skip: !const bool.fromEnvironment('LIVE_BOOK_TEST'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
