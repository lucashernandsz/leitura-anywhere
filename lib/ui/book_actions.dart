import 'package:flutter/material.dart';

import '../data/book.dart';
import 'book_cover.dart';

class BookActions extends StatelessWidget {
  final LocalBook local;
  final bool grouped;

  const BookActions({super.key, required this.local, required this.grouped});

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 359),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 67),
          child: Row(
            children: [
              SizedBox(
                width: 45,
                height: 67,
                child: BookCover(
                  book: local.book,
                  bytes: local.coverBytes,
                  thumbnail: true,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      local.book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Lora',
                        fontSize: 19,
                        height: 24 / 19,
                        fontWeight: FontWeight.w600,
                        color: Color(0xfff5f5f5),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      local.book.author,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        height: 14 / 11,
                        color: Color(0xffa9a9a9),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        for (final (label, icon, code, color) in [
          (
            local.onDesk ? 'Retirar da Sua Mesa' : 'Mover para Sua Mesa',
            local.onDesk ? Icons.remove_circle_outline : Icons.north_east,
            'desk',
            const Color(0xfff1f1f1),
          ),
          (
            'Ler agora',
            Icons.auto_stories_outlined,
            'read',
            const Color(0xffd8d8d8),
          ),
          if (grouped)
            (
              'Ver livros do grupo',
              Icons.layers_outlined,
              'contents',
              const Color(0xffd8d8d8),
            ),
          (
            'Agrupar com outro livro',
            Icons.library_books_outlined,
            'group',
            const Color(0xffd8d8d8),
          ),
          if (grouped)
            (
              'Desagrupar este livro',
              Icons.layers_clear_outlined,
              'ungroup',
              const Color(0xffd8d8d8),
            ),
          (
            'Excluir da Biblioteca',
            Icons.delete_outline,
            'delete',
            const Color(0xffe39898),
          ),
        ]) ...[
          const SizedBox(height: 13),
          InkWell(
            onTap: () => Navigator.pop(context, code),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 43),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 9),
                child: Row(
                  children: [
                    Icon(icon, size: 21, color: color),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 14,
                          height: 18 / 14,
                          color: color,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    ),
  );
}
