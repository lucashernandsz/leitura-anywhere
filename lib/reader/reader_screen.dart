import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/library.dart';
import 'document_cache.dart';
import 'epub_document.dart';
import 'pagination.dart';

class ReaderScreen extends StatefulWidget {
  final Library library;
  final String bookId;
  final VoidCallback? onReady;
  final VoidCallback? onError;
  final FocusNode? focusNode;

  const ReaderScreen({
    super.key,
    required this.library,
    required this.bookId,
    this.onReady,
    this.onError,
    this.focusNode,
  });

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with WidgetsBindingObserver {
  EpubDocument? _document;
  ReaderPagination? _pagination;
  Size? _pageSize;
  MediaQueryData? _layoutMedia;
  Locale? _layoutLocale;
  TextDirection? _layoutDirection;
  double? _layoutFont;
  String? _error;
  String? _saveWarning;
  Timer? _debounce;
  Future<bool> _saveTail = Future<bool>.value(true);
  int _section = 0;
  int _revision = 0;
  int _savedRevision = 0;
  int _page = 0;
  int? _textOffset;
  double _legacyScroll = 0;
  double? _progress;
  double _dragDistance = 0;
  double _fontSize = 22;
  bool _sepia = false;
  bool _loading = true;
  bool _leaving = false;
  bool _allowPop = false;
  bool _needsMarkRead = false;
  bool _readyNotified = false;
  bool _navigationPending = false;
  int _layoutGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _invalidateLayout();
  }

  void _invalidateLayout() {
    // Clear totals before Scaffold builds the footer with the old geometry.
    _layoutGeneration++;
    _pageSize = null;
    _pagination = null;
    _page = -1;
  }

  Future<void> _load() async {
    _layoutGeneration++;
    setState(() {
      _loading = true;
      _error = null;
      _readyNotified = false;
    });
    try {
      var local = widget.library.find(widget.bookId);
      if (local == null) {
        await widget.library.load();
        local = widget.library.find(widget.bookId);
      }
      if (local == null) {
        throw const LibraryException(
          'Livro não encontrado na biblioteca offline.',
        );
      }
      final saved = local;
      final document = await EpubDocumentCache.load(saved.bytes);
      if (!mounted) return;
      setState(() {
        _document = document;
        _pagination = null;
        _pageSize = null;
        _section = saved.section.clamp(0, document.sections.length - 1).toInt();
        _textOffset = _section == saved.section ? saved.textOffset : 0;
        _legacyScroll = _section == saved.section ? saved.scroll : 0;
        _progress = saved.progress;
        _revision++;
        _loading = false;
        _needsMarkRead = true;
      });
      try {
        await widget.library.setOnDesk(widget.bookId, true);
        _needsMarkRead = false;
      } catch (_) {
        _warn(
          'Não foi possível marcar a leitura na biblioteca. Tente novamente ao sair.',
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is FormatException
            ? error.message.toString()
            : error is LibraryException
            ? error.message
            : 'Não foi possível abrir este livro offline.';
      });
      widget.onError?.call();
    }
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () {
      unawaited(_flushPosition());
    });
  }

  void _layoutPages(
    Size size,
    MediaQueryData media,
    TextDirection direction,
    Locale locale,
  ) {
    if (_pageSize == size &&
        _layoutMedia == media &&
        _layoutLocale == locale &&
        _layoutDirection == direction &&
        _layoutFont == _fontSize) {
      return;
    }
    final document = _document!;
    _textOffset ??= ReaderPagination.offsetForLegacyScroll(
      document.sections[_section],
      scroll: _legacyScroll,
      width: size.width,
      textScaler: media.textScaler,
      direction: direction,
    );
    final pagination = ReaderPagination.incremental(
      document,
      size: size,
      fontSize: _fontSize,
      textScaler: media.textScaler,
      direction: direction,
      boldText: media.boldText,
      lineHeight: media.lineHeightScaleFactorOverride,
      letterSpacing: media.letterSpacingOverride,
      wordSpacing: media.wordSpacingOverride,
      locale: locale,
    );
    _pagination = pagination;
    _page = -1;
    _pageSize = size;
    _layoutMedia = media;
    _layoutLocale = locale;
    _layoutDirection = direction;
    _layoutFont = _fontSize;
    final generation = ++_layoutGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _layoutGeneration) return;
      unawaited(_paginate(pagination, generation));
    });
  }

  Future<void> _paginate(ReaderPagination pagination, int generation) async {
    bool current() => mounted && generation == _layoutGeneration;
    try {
      while (current() && !pagination.isComplete) {
        final watch = Stopwatch()..start();
        for (var count = 0; count < 8; count++) {
          var section = _section;
          if (pagination.isSectionComplete(section)) {
            section = 0;
            while (pagination.isSectionComplete(section)) {
              section++;
            }
          }
          pagination.advanceSection(section);
          if ((_page < 0 &&
                  pagination.containsPosition(_section, _textOffset!)) ||
              pagination.isComplete ||
              watch.elapsedMilliseconds >= 4) {
            break;
          }
        }
        if (!current()) return;
        var save = false;
        setState(() {
          if (pagination.containsPosition(_section, _textOffset!)) {
            final firstPage = _page < 0;
            _page = pagination.locate(_section, _textOffset!);
            if (_navigationPending) {
              _textOffset = pagination.pages[_page].start;
              _progress = pagination.progressAt(_page);
              _navigationPending = false;
            }
            _progress ??= pagination.progressAt(_page);
            if (firstPage) {
              _revision++;
              save = true;
            }
          }
        });
        if (save) _scheduleSave();
        // Publish the real page before doing more shaping on the UI isolate.
        // endOfFrame also provides a cancellation point on every batch.
        await WidgetsBinding.instance.endOfFrame;
      }
    } catch (_) {
      if (!current()) return;
      setState(
        () => _error = 'Não foi possível calcular as páginas deste livro.',
      );
      widget.onError?.call();
    }
  }

  bool get _canGoBack =>
      _page >= 0 &&
      _pagination != null &&
      (_pagination!.pages[_page].start > 0 ||
          _pagination!.sectionLengths
              .take(_section)
              .any((length) => length > 0));

  bool get _canGoForward =>
      _page >= 0 &&
      _pagination != null &&
      (_pagination!.pages[_page].end < _pagination!.sectionLengths[_section] ||
          _pagination!.sectionLengths
              .skip(_section + 1)
              .any((length) => length > 0));

  void _changePage(int index) {
    final pagination = _pagination;
    if (_leaving || pagination == null || _page < 0 || index == _page) {
      return;
    }
    final page = pagination.pages[_page];
    if (index > _page) {
      if (!_canGoForward) return;
      if (page.end < pagination.sectionLengths[_section]) {
        _goTo(_section, page.end);
      } else {
        var section = _section + 1;
        while (pagination.sectionLengths[section] == 0) {
          section++;
        }
        _goTo(section, 0);
      }
    } else {
      if (!_canGoBack) return;
      if (page.start > 0) {
        _goTo(_section, page.start - 1);
      } else {
        var section = _section - 1;
        while (pagination.sectionLengths[section] == 0) {
          section--;
        }
        _goTo(section, pagination.sectionLengths[section]);
      }
    }
  }

  void _goTo(int section, int offset) {
    final pagination = _pagination!;
    setState(() {
      _section = section;
      _textOffset = offset;
      _page = pagination.containsPosition(section, offset)
          ? pagination.locate(section, offset)
          : -1;
      _navigationPending = _page < 0;
      if (!_navigationPending) {
        _textOffset = pagination.pages[_page].start;
        _progress = pagination.progressAt(_page);
      } else {
        final before = pagination.sectionLengths
            .take(section)
            .fold(0, (a, b) => a + b);
        final total = pagination.sectionLengths.fold(0, (a, b) => a + b);
        _progress = total == 0 ? 0 : (before + offset) / total;
      }
      _revision++;
    });
    _scheduleSave();
  }

  Map<ShortcutActivator, VoidCallback> get _pageBindings => {
    const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
        _changePage(_page + 1),
    const SingleActivator(LogicalKeyboardKey.pageDown): () =>
        _changePage(_page + 1),
    const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
        _changePage(_page - 1),
    const SingleActivator(LogicalKeyboardKey.pageUp): () =>
        _changePage(_page - 1),
  };

  // Every caller receives a handled Future. Serialize snapshots so an older
  // in-flight write cannot overwrite the newest section or restored offset.
  Future<bool> _flushPosition() {
    _debounce?.cancel();
    final revision = _revision;
    final section = _section;
    final offset = _textOffset;
    final progress = _progress;
    final result = _saveTail.then((_) async {
      if (_document == null ||
          offset == null ||
          (revision <= _savedRevision && !_needsMarkRead)) {
        return true;
      }
      try {
        if (_needsMarkRead) {
          await widget.library.setOnDesk(widget.bookId, true);
          _needsMarkRead = false;
        }
        await widget.library.updatePosition(
          widget.bookId,
          section,
          0,
          textOffset: offset,
          progress: progress,
        );
        _savedRevision = revision;
        if (mounted && _saveWarning != null) {
          setState(() {
            _saveWarning = null;
            _invalidateLayout();
          });
        }
        return true;
      } catch (_) {
        _warn(
          'Não foi possível salvar a posição. Volte novamente para tentar salvar antes de sair.',
        );
        return false;
      }
    });
    _saveTail = result;
    return result;
  }

  void _warn(String message) {
    if (!mounted) return;
    setState(() {
      final changedHeight = _saveWarning == null;
      _saveWarning = message;
      if (changedHeight) _invalidateLayout();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_flushPosition());
    }
  }

  Future<void> _leave() async {
    if (_leaving) return;
    setState(() => _leaving = true);
    final saved = await _flushPosition();
    if (!mounted) return;
    if (!saved) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Sair sem salvar?'),
          content: const Text(
            'A posição mais recente não foi salva. Ao sair, você pode voltar à última posição salva.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Continuar lendo'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Sair sem salvar'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (discard != true) {
        setState(() => _leaving = false);
        return;
      }
    }
    setState(() => _allowPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  void _changeSection(int index) {
    final document = _document;
    if (document == null ||
        _leaving ||
        index == _section ||
        index < 0 ||
        index >= document.sections.length) {
      return;
    }
    final pagination = _pagination;
    if (pagination != null && pagination.sectionLengths[index] > 0) {
      _goTo(index, 0);
    }
  }

  Future<void> _showContents(ThemeData theme) async {
    final document = _document;
    if (document == null) return;
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      backgroundColor: theme.colorScheme.surface,
      builder: (context) => Theme(
        data: theme,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Sumário', style: TextStyle(fontSize: 22)),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: document.sections.length,
                  itemBuilder: (context, index) => ListTile(
                    selected: index == _section,
                    leading: Text('${index + 1}'),
                    title: Text(document.sections[index].title),
                    trailing: index == _section
                        ? const Icon(Icons.bookmark)
                        : null,
                    onTap: () => Navigator.of(context).pop(index),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted && selected != null) _changeSection(selected);
  }

  Future<void> _showSettings() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, updateSheet) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Ajustes de leitura', style: TextStyle(fontSize: 20)),
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 16,
                children: [
                  IconButton(
                    tooltip: 'Diminuir fonte',
                    onPressed: _fontSize <= 18
                        ? null
                        : () {
                            setState(() {
                              _fontSize -= 2;
                              _invalidateLayout();
                            });
                            updateSheet(() {});
                          },
                    icon: const Text('A−', style: TextStyle(fontSize: 20)),
                  ),
                  Text('Fonte ${_fontSize.toInt()}'),
                  IconButton(
                    tooltip: 'Aumentar fonte',
                    onPressed: _fontSize >= 30
                        ? null
                        : () {
                            setState(() {
                              _fontSize += 2;
                              _invalidateLayout();
                            });
                            updateSheet(() {});
                          },
                    icon: const Text('A+', style: TextStyle(fontSize: 20)),
                  ),
                ],
              ),
              SwitchListTile(
                title: const Text('Tema sépia'),
                value: _sepia,
                onChanged: (value) {
                  setState(() => _sepia = value);
                  updateSheet(() {});
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  void dispose() {
    _layoutGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final media = MediaQuery.of(context);
    final background = _sepia
        ? const Color(0xffefe4cd)
        : const Color(0xff080808);
    final ink = _sepia ? const Color(0xff30271e) : const Color(0xfff7f3eb);
    final accent = _sepia ? const Color(0xff715021) : const Color(0xffd7bd8a);
    final theme = base.copyWith(
      brightness: _sepia ? Brightness.light : Brightness.dark,
      scaffoldBackgroundColor: background,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: _sepia ? Brightness.light : Brightness.dark,
        surface: background,
        onSurface: ink,
        primary: accent,
      ),
      textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: background,
        foregroundColor: ink,
      ),
    );
    final document = _document;
    return PopScope<Object?>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_leave());
      },
      child: CallbackShortcuts(
        bindings: _pageBindings,
        child: Theme(
          data: theme,
          child: Scaffold(
            appBar: AppBar(
              leading: IconButton(
                tooltip: 'Salvar e voltar',
                icon: const Icon(Icons.arrow_back),
                onPressed: _leaving ? null : () => unawaited(_leave()),
              ),
              title: Text(
                document?.title ?? 'Leitor offline',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              actions: [
                IconButton(
                  tooltip: 'Ajustes de leitura',
                  onPressed: document == null || _leaving
                      ? null
                      : () => unawaited(_showSettings()),
                  icon: const Icon(Icons.text_fields),
                ),
                IconButton(
                  tooltip: 'Sumário',
                  onPressed: document == null || _leaving
                      ? null
                      : () => unawaited(_showContents(theme)),
                  icon: const Icon(Icons.format_list_bulleted),
                ),
              ],
            ),
            body: AbsorbPointer(absorbing: _leaving, child: _body(ink)),
            bottomNavigationBar: document == null || _loading || _error != null
                ? null
                : SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              IconButton(
                                tooltip: 'Página anterior',
                                onPressed: !_canGoBack || _leaving
                                    ? null
                                    : () => _changePage(_page - 1),
                                icon: const Icon(Icons.chevron_left),
                              ),
                              Expanded(
                                child: Text(
                                  _pagination == null ||
                                          _page < 0 ||
                                          !_pagination!.isComplete
                                      ? 'Calculando páginas…'
                                      : 'Página ${_page + 1} de ${_pagination!.pages.length}',
                                  key: const ValueKey('reader-page-number'),
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Próxima página',
                                onPressed: !_canGoForward || _leaving
                                    ? null
                                    : () => _changePage(_page + 1),
                                icon: const Icon(Icons.chevron_right),
                              ),
                            ],
                          ),
                          SizedBox(
                            height: media.textScaler.scale(14) * 2,
                            child: Center(
                              child: Text(
                                _pagination == null || _page < 0
                                    ? ''
                                    : !_pagination!.isSectionComplete(_section)
                                    ? 'Calculando páginas do capítulo…'
                                    : switch (_pagination!.remainingInChapter(
                                        _page,
                                      )) {
                                        0 => 'Última página do capítulo',
                                        1 => 'Falta 1 página no capítulo',
                                        final remaining =>
                                          'Faltam $remaining páginas no capítulo',
                                      },
                                key: const ValueKey('reader-chapter-remaining'),
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  height: 14 / 11,
                                  color: ink.withValues(alpha: 0.65),
                                ),
                              ),
                            ),
                          ),
                          if (_saveWarning != null)
                            TextButton.icon(
                              onPressed: () => unawaited(_flushPosition()),
                              icon: const Icon(Icons.warning_amber, size: 16),
                              label: const Text('Tentar salvar posição'),
                            ),
                        ],
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _body(Color ink) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(
          semanticsLabel: 'Abrindo EPUB offline',
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => unawaited(_load()),
                icon: const Icon(Icons.refresh),
                label: const Text('Tentar novamente'),
              ),
            ],
          ),
        ),
      );
    }
    return SafeArea(
      top: false,
      bottom: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = Size(
                  constraints.maxWidth,
                  math.max(1, constraints.maxHeight),
                );
                _layoutPages(
                  size,
                  MediaQuery.of(context),
                  Directionality.of(context),
                  Localizations.localeOf(context),
                );
                if (_page < 0) {
                  return const Center(
                    child: CircularProgressIndicator(
                      semanticsLabel: 'Calculando página da posição salva',
                    ),
                  );
                }
                final page = _pagination!.pages[_page];
                if (!_readyNotified) {
                  final generation = _layoutGeneration;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted ||
                        generation != _layoutGeneration ||
                        _page < 0 ||
                        _readyNotified) {
                      return;
                    }
                    _readyNotified = true;
                    widget.onReady?.call();
                  });
                }
                return CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.space): () =>
                        _changePage(_page + 1),
                  },
                  child: Focus(
                    focusNode: widget.focusNode,
                    autofocus: true,
                    child: SelectionArea(
                      child: GestureDetector(
                        key: const ValueKey('reader-page'),
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragStart: (_) => _dragDistance = 0,
                        onHorizontalDragUpdate: (details) =>
                            _dragDistance += details.primaryDelta ?? 0,
                        onHorizontalDragEnd: (details) {
                          final velocity = details.primaryVelocity ?? 0;
                          final direction = _dragDistance.abs() >= 48
                              ? _dragDistance
                              : velocity.abs() >= 300
                              ? velocity
                              : 0;
                          if (direction != 0) {
                            _changePage(_page + (direction < 0 ? 1 : -1));
                          }
                        },
                        child: SizedBox.expand(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final fragment in page.fragments) ...[
                                SizedBox(
                                  height: fragment.height,
                                  child: fragment.block.image != null
                                      ? Semantics(
                                          image: true,
                                          label: fragment.text,
                                          child: Image.memory(
                                            fragment.block.image!,
                                            excludeFromSemantics: true,
                                            fit: BoxFit.contain,
                                            cacheWidth: 1440,
                                            errorBuilder:
                                                (context, error, trace) =>
                                                    const Center(
                                                      child: Text(
                                                        'Imagem indisponível',
                                                      ),
                                                    ),
                                          ),
                                        )
                                      : Semantics(
                                          header:
                                              fragment.block.headingLevel > 0,
                                          child: fragment.scaleDown
                                              ? FittedBox(
                                                  fit: BoxFit.scaleDown,
                                                  alignment: Alignment.topLeft,
                                                  child: SizedBox(
                                                    width: size.width,
                                                    child: _fragmentText(
                                                      fragment,
                                                      ink,
                                                    ),
                                                  ),
                                                )
                                              : _fragmentText(fragment, ink),
                                        ),
                                ),
                                SizedBox(height: fragment.gap),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _fragmentText(PageFragment fragment, Color ink) => Text(
    fragment.displayText,
    style: readerTextStyle(fragment.block, _fontSize).copyWith(color: ink),
    textAlign: TextAlign.start,
    textHeightBehavior: const TextHeightBehavior(),
  );
}
