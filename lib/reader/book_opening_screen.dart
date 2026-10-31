import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/library.dart';
import '../ui/desk_book.dart';
import 'reader_screen.dart';

/// Keeps the real reader mounted while the cover opens over its first page.
class BookOpeningScreen extends StatefulWidget {
  final Library library;
  final LocalBook local;
  final BookOpeningOrigin? origin;
  final VoidCallback? onOpened;

  const BookOpeningScreen({
    super.key,
    required this.library,
    required this.local,
    this.origin,
    this.onOpened,
  });

  @override
  State<BookOpeningScreen> createState() => _BookOpeningScreenState();
}

class _BookOpeningScreenState extends State<BookOpeningScreen>
    with SingleTickerProviderStateMixin {
  late final _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  final _ready = Completer<void>();
  final _readerFocus = FocusNode();
  bool _started = false;
  bool _failed = false;
  bool _opened = false;
  bool _reduceMotion = false;
  bool _holding = false;

  @override
  void initState() {
    super.initState();
    _animation.addListener(_holdUntilReady);
  }

  void _holdUntilReady() {
    if (!_ready.isCompleted &&
        !_holding &&
        !_failed &&
        !_reduceMotion &&
        _animation.value >= 0.7) {
      _holding = true;
      _animation.stop(canceled: false);
      _animation.value = 0.7;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    if (_reduceMotion) {
      _animation.value = 1;
      _notifyOpened();
    }
    if (!_started) {
      _started = true;
      if (!_reduceMotion) unawaited(_open());
    }
  }

  Future<void> _open() async {
    try {
      await _animation.forward().orCancel;
      if (_animation.value < 1) {
        if (!_ready.isCompleted) await _ready.future;
        if (!mounted || _failed || _reduceMotion) return;
        await _animation
            .animateTo(1, duration: const Duration(milliseconds: 270))
            .orCancel;
      }
      _notifyOpened();
    } on TickerCanceled {
      // Leaving the route cancels both animation stages.
    }
  }

  void _notifyOpened() {
    if (_opened || _failed || !_ready.isCompleted) return;
    _opened = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _readerFocus.requestFocus();
      widget.onOpened?.call();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _onReady() {
    if (_failed) setState(() => _failed = false);
    if (!_ready.isCompleted) _ready.complete();
    if (_reduceMotion || _animation.isCompleted) _notifyOpened();
  }

  void _onError() {
    if (!mounted) return;
    setState(() => _failed = true);
    _animation.value = 1;
    if (!_ready.isCompleted) _ready.complete();
  }

  @override
  void dispose() {
    _animation.dispose();
    _readerFocus.dispose();
    if (!_ready.isCompleted) _ready.complete();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _animation,
    child: ReaderScreen(
      library: widget.library,
      bookId: widget.local.book.id,
      onReady: _onReady,
      onError: _onError,
      focusNode: _readerFocus,
    ),
    builder: (context, reader) {
      final progress = _animation.value;
      final reveal = _failed || _reduceMotion
          ? 1.0
          : ((progress - 0.7) / 0.3).clamp(0.0, 1.0);
      final done = reveal >= 1;
      return Material(
        type: MaterialType.transparency,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
              color: const Color(
                0xff080808,
              ).withValues(alpha: (progress / 0.45).clamp(0.0, 1.0)),
            ),
            IgnorePointer(
              ignoring: !done,
              child: ExcludeFocus(
                excluding: !done,
                child: ExcludeSemantics(
                  excluding: !done,
                  // A zero opacity suppresses paint. Keep the first real page
                  // painted before onReady, while visually covered by the book.
                  child: Opacity(
                    opacity: math.max(0.001, reveal),
                    child: reader,
                  ),
                ),
              ),
            ),
            if (!done) ...[
              Positioned.fill(
                child: IgnorePointer(
                  child: ExcludeSemantics(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final size = constraints.biggest;
                        final origin = widget.origin;
                        // Rects are captured in global coordinates, relative to the
                        // same root Navigator as this full-screen route.
                        final start =
                            origin?.bounds ??
                            Rect.fromCenter(
                              center: size.center(Offset.zero),
                              width: math.min(320, size.width * 0.7),
                              height: math.min(448, size.height * 0.6),
                            );
                        final target = Rect.fromCenter(
                          center: size.center(Offset.zero),
                          width: math.min(900, size.width * 1.2),
                          height: size.height * 1.15,
                        );
                        final move = Curves.easeInOutCubic.transform(
                          (progress / 0.7).clamp(0.0, 1.0),
                        );
                        final rect = Rect.lerp(start, target, move)!;
                        return Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Positioned.fromRect(
                              rect: rect,
                              child: Opacity(
                                opacity: 1 - reveal,
                                child: DeskBook(
                                  book: widget.local.book,
                                  bytes: widget.local.coverBytes,
                                  initialYaw: origin?.yaw ?? -0.38,
                                  initialPitch: origin?.pitch ?? -0.12,
                                  showControls: false,
                                  opening: Curves.easeInOutCubic.transform(
                                    ((progress - 0.15) / 0.55).clamp(0.0, 1.0),
                                  ),
                                  onOpen: () {},
                                  onOrganize: () {},
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: IconButton(
                    tooltip: 'Cancelar abertura',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back),
                  ),
                ),
              ),
              if (progress >= 0.7 && !_ready.isCompleted)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: SafeArea(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Semantics(
                        liveRegion: true,
                        child: const Text('Preparando sua leitura...'),
                      ),
                    ),
                  ),
                ),
            ],
          ],
        ),
      );
    },
  );
}
