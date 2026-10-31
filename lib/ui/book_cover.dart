import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/book.dart';
import '../data/catalog.dart' show catalogTransportUri;

class BookCover extends StatelessWidget {
  final Book book;
  final Uint8List? bytes;
  final bool dimensional;
  final bool thumbnail;
  final bool framed;

  const BookCover({
    super.key,
    required this.book,
    this.bytes,
    this.dimensional = false,
    this.thumbnail = false,
    this.framed = false,
  });

  Widget _fallback() {
    const palette = [
      Color(0xffb6a47c),
      Color(0xff48635c),
      Color(0xff8d4f42),
      Color(0xff3f536e),
    ];
    final hash = book.id.codeUnits.fold<int>(0, (sum, value) => sum + value);
    return Container(
      color: palette[hash % palette.length],
      child: FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: 180,
          height: 270,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 22, 12, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(
                  width: 30,
                  child: Divider(color: Colors.white70, thickness: 2),
                ),
                const Spacer(),
                Flexible(
                  flex: 5,
                  child: Text(
                    book.title,
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Lora',
                      color: Colors.white,
                      fontSize: 20,
                      height: 1.15,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Flexible(
                  flex: 2,
                  child: Text(
                    book.author,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 10),
                  ),
                ),
                const Spacer(),
                const Text(
                  'LEITURA',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 8,
                    letterSpacing: 3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget image;
    if (bytes != null) {
      image = Image.memory(
        bytes!,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _fallback(),
        excludeFromSemantics: true,
      );
    } else if (book.coverUrl != null) {
      image = Image.network(
        catalogTransportUri(Uri.parse(book.coverUrl!)).toString(),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _fallback(),
        excludeFromSemantics: true,
      );
    } else {
      image = _fallback();
    }
    return Semantics(
      image: true,
      label: 'Capa de ${book.title}',
      child: Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.001)
          ..rotateY(dimensional ? -0.14 : 0),
        child: AspectRatio(
          aspectRatio: thumbnail ? (framed ? 92 / 130 : 112 / 160) : 0.67,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(
                framed
                    ? 7
                    : thumbnail
                    ? 0
                    : 3,
              ),
              border: framed
                  ? Border.all(color: const Color(0xffccd0d4))
                  : null,
              boxShadow: [
                if (!thumbnail)
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.65),
                    offset: Offset(dimensional ? 18 : 4, dimensional ? 28 : 8),
                    blurRadius: dimensional ? 32 : 12,
                  ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(
                framed
                    ? 6
                    : thumbnail
                    ? 0
                    : 3,
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  image,
                  if (dimensional)
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Color(0x66000000),
                            Color(0x11ffffff),
                            Color(0x00000000),
                            Color(0x22000000),
                          ],
                          stops: [0, 0.035, 0.08, 1],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
