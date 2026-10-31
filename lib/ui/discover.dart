import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app.dart' show gold, muted;
import '../data/book.dart';
import '../data/catalog.dart';
import '../data/catalog_settings.dart';
import '../data/catalog_sources.dart';
import '../data/library.dart';
import '../reader/document_cache.dart';
import '../reader/epub_document.dart';
import 'book_cover.dart';
import 'catalog_settings_screen.dart';
import 'shelf.dart';

class DiscoverScreen extends StatefulWidget {
  final Library library;
  final BookCatalog catalog;
  final CatalogSettings catalogSettings;
  final Future<void> Function(LocalBook) onOpen;
  final VoidCallback onLibrary;
  final bool active;

  const DiscoverScreen({
    super.key,
    required this.library,
    required this.catalog,
    required this.catalogSettings,
    required this.onOpen,
    required this.onLibrary,
    this.active = true,
  });

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  final _search = TextEditingController();
  List<Book> _books = [];
  Timer? _debounce;
  String? _topic = 'psychology';
  String? _error;
  String? _downloadError;
  String? _downloading;
  double? _progress;
  bool _loading = false;
  bool _hasNext = false;
  int _page = 0;
  int _request = 0;

  CatalogSources? get _sources => widget.catalog is CatalogSources
      ? widget.catalog as CatalogSources
      : null;
  bool get _isZLibrary => _sources?.isZLibrary == true;
  BookCatalog get _provider => _sources == null
      ? widget.catalog
      : _isZLibrary
      ? _sources!.zLibrary
      : _sources!.primary;

  @override
  void initState() {
    super.initState();
    _sources?.addListener(_sourceChanged);
    if (widget.active) _restoreSession();
    _load();
  }

  void _restoreSession() {
    final sources = _sources;
    if (sources != null) {
      unawaited(sources.restoreSession(selectRestoredSource: false));
    }
  }

  void _sourceChanged() {
    _downloadError = null;
    _load();
  }

  @override
  void didUpdateWidget(covariant DiscoverScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.catalog != widget.catalog) {
      if (oldWidget.catalog case final CatalogSources sources) {
        sources.removeListener(_sourceChanged);
      }
      _sources?.addListener(_sourceChanged);
      _load();
    }
    if (widget.active &&
        (!oldWidget.active || oldWidget.catalog != widget.catalog)) {
      _restoreSession();
    }
  }

  Future<void> _openSettings() async {
    if (_downloading != null) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CatalogSettingsScreen(
          settings: widget.catalogSettings,
          activeCatalog: widget.catalog.displayName,
          sources: _sources,
        ),
      ),
    );
  }

  Future<void> _load({bool more = false}) async {
    _debounce?.cancel();
    final request = ++_request;
    final nextPage = more ? _page + 1 : 1;
    if (_isZLibrary && _search.text.trim().isEmpty) {
      setState(() {
        _books = [];
        _loading = false;
        _hasNext = false;
        _page = 0;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      if (!more) {
        _books = [];
        _hasNext = false;
      }
    });
    try {
      final result = await _provider.search(
        query: _search.text,
        topic: _isZLibrary ? null : _topic,
        page: nextPage,
      );
      if (!mounted || request != _request) return;
      setState(() {
        _books = more
            ? [
                ..._books,
                ...result.books.where(
                  (book) => !_books.any((b) => b.id == book.id),
                ),
              ]
            : result.books;
        _hasNext = result.hasNext;
        _page = result.page;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(
        () => _error = error is ApiException
            ? error.message
            : 'Não foi possível buscar livros. Tente novamente.',
      );
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Future<void> _download(Book book) async {
    if (_downloading != null) return;
    final provider = _provider;
    setState(() {
      _downloading = book.id;
      _progress = null;
      _downloadError = null;
    });
    try {
      final bytes = await provider.download(
        book,
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      final document = await EpubDocument.parse(bytes);
      await widget.library.add(book, bytes, coverBytes: document.cover);
      final saved = widget.library.find(book.id);
      if (saved != null) EpubDocumentCache.remember(saved.bytes, document);
    } catch (error) {
      if (mounted) {
        setState(
          () => _downloadError = error is ApiException
              ? error.message
              : error is FormatException
              ? error.message.toString()
              : 'Não foi possível salvar o livro. Verifique a conexão e o armazenamento.',
        );
      }
    } finally {
      if (mounted) setState(() => _downloading = null);
    }
  }

  Future<void> _details(Book book) async {
    final local = widget.library.find(book.id);
    final provider = _provider;
    final selected = await showBookPanel<String>(
      context: context,
      child: ListenableBuilder(
        listenable: _sources ?? widget.library,
        builder: (context, _) {
          final needsLogin =
              provider == _sources?.zLibrary &&
              !_sources!.zLibrary.isAuthenticated;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                book.title,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(book.author, style: const TextStyle(color: muted)),
              const SizedBox(height: 24),
              Text(
                'EPUB · ${book.source}',
                style: const TextStyle(color: gold),
              ),
              const SizedBox(height: 12),
              if (book.subjects.isNotEmpty)
                Text(
                  book.subjects.take(4).join(' · '),
                  style: const TextStyle(color: muted, height: 1.6),
                ),
              const SizedBox(height: 18),
              Text(
                provider.usageNotice,
                style: const TextStyle(color: muted, fontSize: 12, height: 1.6),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed:
                      provider == _provider &&
                          (local != null ||
                              (book.downloadable && _downloading == null))
                      ? () => Navigator.pop(
                          context,
                          local != null
                              ? 'read'
                              : needsLogin
                              ? 'connect'
                              : 'download',
                        )
                      : null,
                  icon: Icon(
                    local != null
                        ? Icons.auto_stories_outlined
                        : needsLogin
                        ? Icons.manage_accounts_outlined
                        : Icons.download_outlined,
                  ),
                  label: Text(
                    local != null
                        ? 'Ler offline'
                        : needsLogin
                        ? 'Conectar conta para baixar'
                        : book.downloadable
                        ? 'Baixar para a biblioteca'
                        : 'EPUB indisponível',
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
    if (!mounted || selected == null || provider != _provider) return;
    if (local != null) {
      await widget.onOpen(local);
    } else if (selected == 'connect' ||
        (_isZLibrary && !_sources!.zLibrary.isAuthenticated)) {
      await _openSettings();
    } else {
      await _download(book);
    }
  }

  @override
  void dispose() {
    _sources?.removeListener(_sourceChanged);
    _request++;
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: _load,
    child: CustomScrollView(
      key: const PageStorageKey('discover-scroll'),
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  24,
                  math.max(0, 62 - MediaQuery.viewPaddingOf(context).top) + 12,
                  24,
                  4,
                ),
                child: Row(
                  key: const ValueKey('discover-heading'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        'Descobrir',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Lora',
                          fontSize: 28,
                          height: 36 / 28,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Fontes e contas',
                      onPressed: _downloading == null ? _openSettings : null,
                      icon: const Icon(Icons.manage_accounts_outlined),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: SizedBox(
                  key: const ValueKey('discover-search'),
                  height: math.max(
                    48,
                    MediaQuery.textScalerOf(context).scale(17) + 30,
                  ),
                  child: TextField(
                    controller: _search,
                    style: const TextStyle(fontSize: 13, height: 17 / 13),
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: _isZLibrary
                          ? 'Título ou autor'
                          : 'Título, autor ou assunto',
                      hintStyle: const TextStyle(color: Color(0xffa8a8a8)),
                      fillColor: const Color(0xff151515),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        vertical: 15,
                        horizontal: 12,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xff343434)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xff777777)),
                      ),
                      prefixIconConstraints: const BoxConstraints(minWidth: 42),
                      prefixIcon: const Padding(
                        padding: EdgeInsets.only(left: 14, right: 10),
                        child: Icon(
                          Icons.search,
                          size: 18,
                          color: Color(0xffbdbdbd),
                        ),
                      ),
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Limpar busca',
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () {
                                _search.clear();
                                _load();
                              },
                            ),
                    ),
                    onSubmitted: (_) => _load(),
                    onChanged: (_) {
                      // Invalidate an in-flight response before the debounce starts a new one.
                      _request++;
                      setState(() {});
                      _debounce?.cancel();
                      _debounce = Timer(
                        const Duration(milliseconds: 500),
                        _load,
                      );
                    },
                  ),
                ),
              ),
              if (_isZLibrary)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                  child: Text(
                    'Fonte: Z-Library. ${_sources!.zLibrary.isAuthenticated ? 'Conta conectada.' : 'Conecte sua conta em Fontes e contas para baixar.'}',
                    style: const TextStyle(color: muted),
                  ),
                ),
              if (!_isZLibrary)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      const topics = [
                        'psychology',
                        'business',
                        'philosophy',
                        'fiction',
                        'history',
                        null,
                      ];
                      return SizedBox(
                        key: const ValueKey('discover-categories'),
                        height: 36,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            for (var page = 0; page < 2; page++)
                              SizedBox(
                                width: constraints.maxWidth,
                                child: ShelfFilters(
                                  categories: true,
                                  labels: page == 0
                                      ? const [
                                          'Psicologia',
                                          'Carreira',
                                          'Filosofia',
                                        ]
                                      : const [
                                          'Literatura',
                                          'História',
                                          'Para você',
                                        ],
                                  selected: topics.indexOf(_topic) - page * 3,
                                  onSelected: (index) {
                                    setState(
                                      () => _topic = topics[page * 3 + index],
                                    );
                                    _load();
                                  },
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              if (_downloading != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 10, 24, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _progress == 1
                            ? 'Preparando o livro para leitura…'
                            : 'Baixando EPUB${_progress == null ? '' : ' · ${(_progress! * 100).round()}%'}',
                        style: const TextStyle(color: gold, fontSize: 12),
                      ),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: _progress == 1 ? null : _progress,
                      ),
                    ],
                  ),
                ),
              if (_downloadError != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.error_outline,
                        size: 20,
                        color: Color(0xffedaaa0),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _downloadError!,
                          style: const TextStyle(color: Color(0xffedaaa0)),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Fechar aviso',
                        onPressed: () => setState(() => _downloadError = null),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        if (_books.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            sliver: SliverShelf(
              itemWidth: 112,
              step: 122,
              itemCount: _books.length,
              itemBuilder: (context, index) {
                final book = _books[index];
                final local = widget.library.find(book.id);
                return Semantics(
                  button: true,
                  label: '${book.title}, ${book.author}',
                  child: Tooltip(
                    message: '${book.title} · ${book.author}',
                    child: InkWell(
                      key: ValueKey('discover-cover-${book.id}'),
                      onTap: () => _details(book),
                      child: BookCover(
                        book: book,
                        bytes: local?.coverBytes,
                        thumbnail: true,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        if (_loading && _books.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          ),
        if (_error != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                children: [
                  const Icon(Icons.wifi_off_outlined, color: muted, size: 32),
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: muted),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: _loading
                        ? null
                        : () => _load(more: _books.isNotEmpty),
                    child: const Text('Tentar novamente'),
                  ),
                ],
              ),
            ),
          ),
        if (!_loading && _error == null && _books.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  _isZLibrary && _search.text.trim().isEmpty
                      ? 'Busque um t\u00edtulo ou autor no Z-Library.'
                      : 'Nenhum livro encontrado.\nTente outro título, autor ou assunto.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: muted, height: 1.6),
                ),
              ),
            ),
          ),
        if (_hasNext && _error == null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: OutlinedButton(
                  onPressed: _loading ? null : () => _load(more: true),
                  child: Text(_loading ? 'Buscando…' : 'Explorar mais livros'),
                ),
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 18)),
      ],
    ),
  );
}
