import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/book.dart';
import 'book_cover.dart';

class BookOpeningOrigin {
  final Rect bounds;
  final double yaw;
  final double pitch;

  const BookOpeningOrigin(this.bounds, this.yaw, this.pitch);
}

/// A closed book with independently projected cover, spine and page edges.
class DeskBook extends StatefulWidget {
  final Book book;
  final Uint8List? bytes;
  final VoidCallback onOpen;
  final VoidCallback onOrganize;
  final ValueChanged<int>? onBrowse;
  final ValueChanged<BookOpeningOrigin>? onOpenWithOrigin;
  final double opening;
  final double initialYaw;
  final double initialPitch;
  final bool showControls;

  const DeskBook({
    super.key,
    required this.book,
    this.bytes,
    required this.onOpen,
    required this.onOrganize,
    this.onBrowse,
    this.onOpenWithOrigin,
    this.opening = 0,
    this.initialYaw = -0.38,
    this.initialPitch = -0.12,
    this.showControls = true,
  });

  @override
  State<DeskBook> createState() => _DeskBookState();
}

class _DeskBookState extends State<DeskBook> {
  static const _initialYaw = -0.38;
  static const _initialPitch = -0.12;
  final _focus = FocusNode();
  double _yaw = _initialYaw;
  double _pitch = _initialPitch;
  bool _dragging = false;
  Offset _dragOffset = Offset.zero;
  bool? _browseGesture;

  @override
  void initState() {
    super.initState();
    _yaw = widget.initialYaw;
    _pitch = widget.initialPitch;
  }

  void _open() {
    final callback = widget.onOpenWithOrigin;
    final box = context.findRenderObject();
    if (callback != null && box is RenderBox && box.hasSize) {
      callback(
        BookOpeningOrigin(
          box.localToGlobal(Offset.zero) & box.size,
          _yaw,
          _pitch,
        ),
      );
    } else {
      widget.onOpen();
    }
  }

  @override
  void didUpdateWidget(covariant DeskBook oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.book.id != widget.book.id) {
      _yaw = _initialYaw;
      _pitch = _initialPitch;
      _dragging = false;
      _dragOffset = Offset.zero;
      _browseGesture = null;
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _rotate(double yaw, double pitch) => setState(() {
    _yaw = (_yaw + yaw) % (2 * math.pi);
    _pitch = (_pitch + pitch).clamp(-0.85, 0.85);
  });

  void _reset() => setState(() {
    _yaw = _initialYaw;
    _pitch = _initialPitch;
  });

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        widget.onBrowse != null ? widget.onBrowse!(-1) : _rotate(-0.15, 0);
      case LogicalKeyboardKey.arrowRight:
        widget.onBrowse != null ? widget.onBrowse!(1) : _rotate(0.15, 0);
      case LogicalKeyboardKey.arrowUp:
        _rotate(0, -0.1);
      case LogicalKeyboardKey.arrowDown:
        _rotate(0, 0.1);
      case LogicalKeyboardKey.home:
        _reset();
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.space:
        if (event is KeyDownEvent) _open();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Widget _model(double width, double height) {
    final depth = width * 0.12;
    final opening = widget.opening.clamp(0.0, 1.0);
    final yaw = (_yaw + math.pi) % (2 * math.pi) - math.pi;
    final rotation = Matrix4.identity()
      ..rotateX(_pitch * (1 - opening))
      ..rotateY(opening == 0 ? _yaw : yaw * (1 - opening));
    final faces =
        <({Matrix4 matrix, double width, double height, Widget child})>[];

    void face({
      required double w,
      required double h,
      double x = 0,
      double y = 0,
      double z = 0,
      double rx = 0,
      double ry = 0,
      double hinge = 0,
      required Widget child,
    }) {
      final matrix = rotation.clone()
        ..translateByDouble(x, y, z, 1)
        ..rotateX(rx)
        ..rotateY(ry);
      if (hinge != 0) {
        matrix
          ..translateByDouble(-w / 2, 0, 0, 1)
          ..rotateY(hinge)
          ..translateByDouble(w / 2, 0, 0, 1);
      }
      // Cull faces pointing away from the perspective camera at z = 1000.
      final facing =
          matrix.entry(2, 2) * (1000 - matrix.entry(2, 3)) -
          matrix.entry(0, 2) * matrix.entry(0, 3) -
          matrix.entry(1, 2) * matrix.entry(1, 3);
      if (facing <= 0) return;
      faces.add((matrix: matrix, width: w, height: h, child: child));
    }

    face(
      w: width,
      h: height,
      z: depth / 2,
      hinge: -math.pi * 0.85 * opening,
      child: Stack(
        fit: StackFit.expand,
        children: [
          BookCover(book: widget.book, bytes: widget.bytes, thumbnail: true),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Color(0x99000000),
                  Color(0x22ffffff),
                  Color(0x00000000),
                  Color(0x22000000),
                ],
                stops: [0, 0.035, 0.09, 1],
              ),
            ),
          ),
        ],
      ),
    );
    if (opening > 0) {
      face(
        w: width,
        h: height,
        z: depth / 2 - 0.5,
        child: const ColoredBox(color: Color(0xff080808)),
      );
    }
    face(
      w: width,
      h: height,
      z: -depth / 2,
      ry: math.pi,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xff262b2a), Color(0xff111514)],
          ),
        ),
        child: Padding(
          padding: EdgeInsets.all(width * 0.12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  widget.book.title,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Lora',
                    fontSize: width * 0.075,
                    color: const Color(0xffd7bd8a),
                  ),
                ),
              ),
              SizedBox(height: height * 0.06),
              const Text(
                'LEITURA',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 8, letterSpacing: 3),
              ),
            ],
          ),
        ),
      ),
    );
    face(
      w: depth,
      h: height,
      x: -width / 2,
      ry: -math.pi / 2,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xff111514), Color(0xff414b44), Color(0xff202622)],
            stops: [0, 0.45, 1],
          ),
        ),
        child: RotatedBox(
          quarterTurns: 3,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                widget.book.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Lora',
                  fontSize: depth * 0.42,
                  color: const Color(0xffd7bd8a),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    face(
      w: depth,
      h: height,
      x: width / 2,
      ry: math.pi / 2,
      child: const CustomPaint(painter: _PageEdges()),
    );
    for (final top in [true, false]) {
      face(
        w: width,
        h: depth,
        y: (top ? -1 : 1) * height / 2,
        rx: (top ? 1 : -1) * math.pi / 2,
        child: const CustomPaint(painter: _PageEdges(horizontal: true)),
      );
    }
    faces.sort((a, b) => a.matrix.entry(2, 3).compareTo(b.matrix.entry(2, 3)));
    return ExcludeSemantics(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            left: width * 0.12,
            right: width * 0.12,
            bottom: height * 0.045,
            height: 10,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(100),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0xaa000000),
                    blurRadius: 25,
                    spreadRadius: 8,
                  ),
                ],
              ),
            ),
          ),
          for (final face in faces)
            Center(
              child: Transform(
                alignment: Alignment.center,
                transform: (Matrix4.identity()..setEntry(3, 2, -0.001))
                  ..multiply(face.matrix),
                child: SizedBox(
                  width: face.width,
                  height: face.height,
                  child: face.child,
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Stack(
      fit: StackFit.expand,
      children: [
        Focus(
          onKeyEvent: _onKey,
          child: Semantics(
            label: 'Ler ${widget.book.title}',
            hint: widget.onBrowse == null
                ? 'Arraste para girar. Use as setas no teclado. '
                      'Mantenha pressionado para organizar.'
                : 'Deslize para os lados ou use as setas para trocar de livro. '
                      'Mantenha pressionado para organizar.',
            onIncrease: () => widget.onBrowse != null
                ? widget.onBrowse!(1)
                : _rotate(0.15, 0),
            onDecrease: () => widget.onBrowse != null
                ? widget.onBrowse!(-1)
                : _rotate(-0.15, 0),
            child: RawGestureDetector(
              gestures: {
                _BookPanGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      _BookPanGestureRecognizer
                    >(
                      _BookPanGestureRecognizer.new,
                      (recognizer) => recognizer
                        ..gestureSettings = MediaQuery.gestureSettingsOf(
                          context,
                        )
                        ..onStart = (_) {
                          _focus.requestFocus();
                          _dragOffset = Offset.zero;
                          _browseGesture = null;
                          setState(() => _dragging = true);
                        }
                        ..onUpdate = (details) {
                          _dragOffset += details.delta;
                          if (_dragOffset == Offset.zero) return;
                          _browseGesture ??=
                              widget.onBrowse != null &&
                              _dragOffset.dx.abs() > _dragOffset.dy.abs();
                          if (_browseGesture!) return;
                          _rotate(
                            details.delta.dx /
                                constraints.maxWidth *
                                2 *
                                math.pi,
                            -details.delta.dy / constraints.maxHeight * math.pi,
                          );
                        }
                        ..onEnd = (_) {
                          setState(() => _dragging = false);
                          if (_browseGesture == true &&
                              _dragOffset.dx.abs() >= 56) {
                            widget.onBrowse!(_dragOffset.dx < 0 ? 1 : -1);
                          }
                        }
                        ..onCancel = () {
                          setState(() => _dragging = false);
                        },
                    ),
              },
              child: InkWell(
                mouseCursor: _dragging
                    ? SystemMouseCursors.grabbing
                    : SystemMouseCursors.grab,
                focusNode: _focus,
                onTap: _open,
                onLongPress: widget.onOrganize,
                overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                splashFactory: NoSplash.splashFactory,
                child: _model(
                  constraints.maxWidth * 0.80,
                  constraints.maxHeight * 0.80,
                ),
              ),
            ),
          ),
        ),
        if (widget.showControls)
          Positioned(
            top: 0,
            right: 0,
            child: IconButton(
              tooltip: 'Restaurar rotação',
              onPressed: _reset,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              icon: const Icon(Icons.restart_alt, size: 20),
            ),
          ),
      ],
    ),
  );
}

// Match scroll's threshold so vertical book drags win over the desk's scroll.
class _BookPanGestureRecognizer extends PanGestureRecognizer {
  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) =>
      globalDistanceMoved.abs() >
      computeHitSlop(pointerDeviceKind, gestureSettings);
}

class _PageEdges extends CustomPainter {
  final bool horizontal;

  const _PageEdges({this.horizontal = false});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xff9b907c), Color(0xffeee5d3), Color(0xffbfb39e)],
        ).createShader(rect),
    );
    final line = Paint()
      ..color = const Color(0xffa99c86)
      ..strokeWidth = 0.5;
    final length = horizontal ? size.height : size.width;
    for (double offset = 1; offset < length; offset += 2) {
      canvas.drawLine(
        horizontal ? Offset(0, offset) : Offset(offset, 0),
        horizontal ? Offset(size.width, offset) : Offset(offset, size.height),
        line,
      );
    }
  }

  @override
  bool shouldRepaint(_PageEdges oldDelegate) =>
      horizontal != oldDelegate.horizontal;
}
