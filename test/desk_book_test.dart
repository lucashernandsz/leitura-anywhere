import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leitura_anywhere/data/book.dart';
import 'package:leitura_anywhere/ui/book_cover.dart';
import 'package:leitura_anywhere/ui/desk_book.dart';

void main() {
  var opened = 0;
  var organized = 0;

  Future<void> showBook(
    WidgetTester tester, {
    String id = 'book',
    bool reducedMotion = false,
    String title = 'Um livro',
    Size size = const Size(300, 420),
    double textScale = 1,
    ValueChanged<int>? onBrowse,
    ValueChanged<BookOpeningOrigin>? onOpenWithOrigin,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            disableAnimations: reducedMotion,
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: DeskBook(
                  key: ValueKey(id),
                  book: Book(
                    id: id,
                    title: title,
                    author: 'Autora',
                    source: 'Teste',
                  ),
                  onOpen: () => opened++,
                  onOrganize: () => organized++,
                  onBrowse: onBrowse,
                  onOpenWithOrigin: onOpenWithOrigin,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<List<double>> matrices(WidgetTester tester) => tester
      .widgetList<Transform>(
        find.descendant(
          of: find.byType(DeskBook),
          matching: find.byType(Transform),
        ),
      )
      .map((widget) => widget.transform.storage.toList())
      .toList();

  setUp(() {
    opened = 0;
    organized = 0;
  });

  testWidgets('cover fills more of its stage while retaining rotation space', (
    tester,
  ) async {
    await showBook(tester);
    expect(tester.getSize(find.byType(BookCover)), const Size(240, 336));
    expect(tester.getSize(find.byType(DeskBook)), const Size(300, 420));
  });

  testWidgets('browsing exposes nonvisual next and previous actions', (
    tester,
  ) async {
    final directions = <int>[];
    await showBook(tester, onBrowse: directions.add);
    final semantics = tester.widget<Semantics>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics && widget.properties.label == 'Ler Um livro',
      ),
    );
    semantics.properties.onIncrease!();
    semantics.properties.onDecrease!();
    expect(directions, [1, -1]);
    expect(opened, 0);
    expect(organized, 0);
  });

  testWidgets('opening captures current rotation and global bounds', (
    tester,
  ) async {
    BookOpeningOrigin? origin;
    await showBook(tester, onOpenWithOrigin: (value) => origin = value);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(DeskBook)),
    );
    await gesture.moveBy(const Offset(25, 0));
    await gesture.moveBy(const Offset(50, 30));
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DeskBook));
    expect(origin, isNotNull);
    expect(origin!.bounds, tester.getRect(find.byType(DeskBook)));
    expect(origin!.yaw, isNot(-0.38));
    expect(origin!.pitch, isNot(-0.12));
    expect(opened, 0);
  });

  for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
    testWidgets('rotation has no rectangular overlay with $kind', (
      tester,
    ) async {
      await showBook(tester);
      final interaction = find.descendant(
        of: find.byType(DeskBook),
        matching: find.byWidgetPredicate(
          (widget) => widget is InkWell && widget.onLongPress != null,
        ),
      );

      void expectNoRectangle() {
        final inkWell = tester.widget<InkWell>(interaction);
        expect(inkWell.splashFactory, NoSplash.splashFactory);
        for (final state in WidgetState.values) {
          expect(inkWell.overlayColor?.resolve({state}), Colors.transparent);
        }
        final decorations = tester.widgetList<DecoratedBox>(
          find.descendant(of: interaction, matching: find.byType(DecoratedBox)),
        );
        expect(
          decorations.where(
            (widget) =>
                widget.decoration is BoxDecoration &&
                (widget.decoration as BoxDecoration).border?.isUniform == true,
          ),
          isEmpty,
        );
      }

      expectNoRectangle();
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(DeskBook)),
        kind: kind,
      );
      await gesture.moveBy(const Offset(25, 0));
      await gesture.moveBy(const Offset(70, 30));
      await tester.pump();
      expect(tester.widget<InkWell>(interaction).focusNode!.hasFocus, isTrue);
      expectNoRectangle();
      await gesture.up();
      await tester.pumpAndSettle();
      expectNoRectangle();
      expect(opened, 0);
      expect(organized, 0);
    });

    testWidgets(
      'drag rotates both axes with $kind without opening the reader',
      (tester) async {
        await showBook(tester);
        final initial = matrices(tester);
        final center = tester.getCenter(find.byType(DeskBook));
        final gesture = await tester.startGesture(center, kind: kind);
        await gesture.moveBy(const Offset(25, 0));
        await gesture.moveBy(const Offset(70, 0));
        await tester.pump();
        final horizontal = matrices(tester);
        expect(horizontal, isNot(equals(initial)));
        await gesture.moveBy(const Offset(0, 70));
        await tester.pump();
        expect(matrices(tester), isNot(equals(horizontal)));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(opened, 0);
        expect(organized, 0);
        await tester.tap(find.byTooltip('Restaurar rotação'));
        await tester.pumpAndSettle();
        expect(matrices(tester), equals(initial));
        expect(opened, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('half turn shows the back instead of a mirrored cover', (
    tester,
  ) async {
    await showBook(tester);
    expect(find.byType(BookCover), findsOneWidget);
    await tester.drag(find.byType(DeskBook), const Offset(170, 0));
    await tester.pumpAndSettle();
    expect(find.byType(BookCover), findsNothing);
    expect(find.text('LEITURA'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('back fits a long title with large text on a small screen', (
    tester,
  ) async {
    await showBook(
      tester,
      title:
          'Uma longa historia com um titulo extenso para testar a contracapa',
      size: const Size(164, 230),
      textScale: 2,
    );
    await tester.drag(find.byType(DeskBook), const Offset(100, 0));
    await tester.pumpAndSettle();
    expect(find.byType(BookCover), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard rotates, resets and opens the focused book', (
    tester,
  ) async {
    await showBook(tester);
    final initial = matrices(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(matrices(tester), isNot(equals(initial)));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(matrices(tester), isNot(equals(initial)));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pump();
    expect(matrices(tester), equals(initial));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(opened, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(opened, 2);
  });

  testWidgets('tap reads, long press organizes, new book resets orientation', (
    tester,
  ) async {
    await showBook(tester);
    final initial = matrices(tester);
    await tester.tap(find.byType(DeskBook));
    await tester.pumpAndSettle();
    expect(opened, 1);
    await tester.longPress(find.byType(DeskBook));
    await tester.pumpAndSettle();
    expect(organized, 1);
    expect(opened, 1);
    await tester.drag(find.byType(DeskBook), const Offset(100, 100));
    await tester.pumpAndSettle();
    expect(matrices(tester), isNot(equals(initial)));
    await showBook(tester, id: 'another');
    expect(matrices(tester), equals(initial));
  });

  testWidgets('reduced motion has no idle animation or inertia', (
    tester,
  ) async {
    await showBook(tester, reducedMotion: true);
    final initial = matrices(tester);
    await tester.pump(const Duration(seconds: 5));
    expect(matrices(tester), equals(initial));
    await tester.drag(find.byType(DeskBook), const Offset(100, 100));
    await tester.pumpAndSettle();
    final rotated = matrices(tester);
    expect(rotated, isNot(equals(initial)));
    await tester.pump(const Duration(seconds: 5));
    expect(matrices(tester), equals(rotated));
    expect(tester.binding.transientCallbackCount, 0);
  });
}
