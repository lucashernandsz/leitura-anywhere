import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leitura_anywhere/data/book.dart';
import 'package:leitura_anywhere/data/catalog.dart';
import 'package:leitura_anywhere/ui/book_cover.dart';

void main() {
  const cover =
      'https://s3proxy-alp2-covers.cdn-zlib.sk/covers299/fiction/cover.jpg';
  Book book({String? coverUrl}) => Book(
    id: 'zlibrary:42:abc123',
    title: 'Livro de teste',
    author: 'Autor',
    source: 'Z-Library',
    coverUrl: coverUrl,
  );

  Widget app(Book book, {Uint8List? bytes}) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 112,
        height: 160,
        child: BookCover(book: book, bytes: bytes, thumbnail: true),
      ),
    ),
  );

  testWidgets(
    'remote cover reaches Image.network and failures keep the illustrated fallback',
    (tester) async {
      await tester.pumpWidget(app(book(coverUrl: cover)));
      final image = tester.widget<Image>(find.byType(Image));
      expect(
        (image.image as NetworkImage).url,
        catalogTransportUri(Uri.parse(cover)).toString(),
      );
      await tester.pumpAndSettle();
      expect(find.text('Livro de teste'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing cover keeps fallback and local EPUB cover takes priority over remote URL',
    (tester) async {
      await tester.pumpWidget(app(book()));
      expect(find.text('Livro de teste'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      final bytes = Uint8List.fromList([1, 2, 3]);
      await tester.pumpWidget(app(book(coverUrl: cover), bytes: bytes));
      expect(
        tester.widget<Image>(find.byType(Image)).image,
        isA<MemoryImage>(),
      );
      await tester.pumpAndSettle();
      expect(find.text('Livro de teste'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
