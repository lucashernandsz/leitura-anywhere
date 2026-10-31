import 'dart:math' as math;

import 'package:flutter/material.dart';

class ShelfFilters extends StatelessWidget {
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;
  final bool categories;

  const ShelfFilters({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelected,
    this.categories = false,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
    height: categories ? 36 : 40,
    child: Padding(
      padding: EdgeInsets.symmetric(
        horizontal: categories ? 9 : 6,
        vertical: categories ? 0 : 1,
      ),
      child: Row(
        children: [
          for (var index = 0; index < labels.length; index++) ...[
            if (index > 0) SizedBox(width: categories ? 8 : 11),
            Expanded(
              child: Semantics(
                selected: selected == index,
                button: true,
                child: Material(
                  color: selected == index
                      ? const Color(0xff292929)
                      : categories
                      ? const Color(0xff080808)
                      : const Color(0xff111111),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(categories ? 18 : 11),
                    side: categories
                        ? BorderSide.none
                        : BorderSide(
                            color: selected == index
                                ? const Color(0xff3a3a3a)
                                : const Color(0xff292929),
                          ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => onSelected(index),
                    child: Center(
                      child: Text(
                        labels[index],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          height: 14 / 11,
                          fontWeight: selected == index
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: selected == index
                              ? const Color(0xfff2f2f2)
                              : categories
                              ? const Color(0xffe0e0e0)
                              : const Color(0xff9a9a9a),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

class SliverShelf extends StatelessWidget {
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final double itemWidth;
  final double step;
  final double itemHeight;

  const SliverShelf({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.itemWidth = 122,
    this.step = 117,
    this.itemHeight = 160,
  });

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.crossAxisExtent;
      final columns = ((width - 26 - itemWidth) / step + 1).floor().clamp(1, 6);
      final left = math.max(
        0.0,
        (width - itemWidth - (columns - 1) * step) / 2,
      );
      final rows = (itemCount / columns).ceil();
      return SliverList.builder(
        itemCount: rows,
        itemBuilder: (context, row) => SizedBox(
          height: itemHeight + (row < rows - 1 ? 12 : 0),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (
                var column = 0;
                column < columns && row * columns + column < itemCount;
                column++
              )
                Positioned(
                  left: left + column * step,
                  top: 0,
                  width: itemWidth,
                  height: itemHeight,
                  child: itemBuilder(context, row * columns + column),
                ),
            ],
          ),
        ),
      );
    },
  );
}

Future<T?> showBookPanel<T>({
  required BuildContext context,
  required Widget child,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  showDragHandle: false,
  backgroundColor: Colors.transparent,
  barrierColor: const Color(0xa8000000),
  constraints: const BoxConstraints(maxWidth: 430),
  builder: (context) => SafeArea(
    minimum: const EdgeInsets.fromLTRB(14, 14, 14, 18),
    child: SingleChildScrollView(
      child: Material(
        key: const ValueKey('book-panel'),
        color: const Color(0xff1d1d1d),
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
          child: SizedBox(width: double.infinity, child: child),
        ),
      ),
    ),
  ),
);
