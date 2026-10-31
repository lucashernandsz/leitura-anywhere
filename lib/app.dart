import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'data/catalog.dart';
import 'data/catalog_settings.dart';
import 'data/library.dart';
import 'reader/book_opening_screen.dart';
import 'reader/document_cache.dart';
import 'reader/pagination.dart';
import 'ui/book_actions.dart';
import 'ui/book_cover.dart';
import 'ui/desk_book.dart';
import 'ui/discover.dart';
import 'ui/shelf.dart';

const paper = Color(0xfff7f3eb);
const muted = Color(0xffaaa59b);
const gold = Color(0xffd7bd8a);

final leituraTheme = ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  scaffoldBackgroundColor: const Color(0xff080808),
  fontFamily: 'DM Sans',
  colorScheme: ColorScheme.fromSeed(
    seedColor: gold,
    brightness: Brightness.dark,
    surface: const Color(0xff131313),
    primary: gold,
    onSurface: paper,
  ),
  textTheme: const TextTheme(
    headlineLarge: TextStyle(fontFamily: 'Lora', fontSize: 32, color: paper),
    headlineMedium: TextStyle(fontFamily: 'Lora', fontSize: 26, color: paper),
    bodyMedium: TextStyle(color: paper, fontSize: 14),
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: Color(0xff080808),
    foregroundColor: paper,
    surfaceTintColor: Colors.transparent,
  ),
  navigationBarTheme: const NavigationBarThemeData(
    backgroundColor: Color(0xff080808),
    indicatorColor: Color(0xff27231c),
    labelTextStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: const Color(0xff181818),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      minimumSize: const Size(48, 50),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  ),
  dividerColor: const Color(0xff292929),
);

class LeituraApp extends StatelessWidget {
  final Library library;
  final BookCatalog catalog;
  final CatalogSettings catalogSettings;

  const LeituraApp({
    super.key,
    required this.library,
    required this.catalog,
    required this.catalogSettings,
  });

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Leitura Anywhere',
    debugShowCheckedModeBanner: false,
    theme: leituraTheme,
    home: HomeScreen(
      library: library,
      catalog: catalog,
      catalogSettings: catalogSettings,
    ),
  );
}

class HomeScreen extends StatefulWidget {
  final Library library;
  final BookCatalog catalog;
  final CatalogSettings catalogSettings;

  const HomeScreen({
    super.key,
    required this.library,
    required this.catalog,
    required this.catalogSettings,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  int _filter = 2;
  int _deskIndex = 0;
  final _legacyProgress = <String, Future<double>>{};
  Uint8List? _selectedBytes;
  Timer? _warmTimer;
  bool _opening = false;

  @override
  void dispose() {
    _warmTimer?.cancel();
    super.dispose();
  }

  Future<void> _open(LocalBook local, {BookOpeningOrigin? origin}) async {
    if (_opening) return;
    _opening = true;
    _warmTimer?.cancel();
    final watch = Stopwatch()..start();
    final timeline = developer.TimelineTask()..start('Book opening');
    var finished = false;
    try {
      await Navigator.of(context).push(
        PageRouteBuilder<void>(
          opaque: false,
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (_, _, _) => BookOpeningScreen(
            library: widget.library,
            local: local,
            origin: origin,
            onOpened: () {
              if (finished) return;
              finished = true;
              timeline.finish(
                arguments: {'elapsedMs': watch.elapsedMilliseconds},
              );
            },
          ),
        ),
      );
    } finally {
      if (!finished) timeline.finish(arguments: {'cancelled': true});
      _opening = false;
    }
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _actions(LocalBook local) async {
    final members = widget.library.groupFor(local.book.id);
    final action = await showBookPanel<String>(
      context: context,
      child: BookActions(local: local, grouped: members.length > 1),
    );
    if (!mounted || action == null) return;
    if (action == 'read') {
      await _open(local);
      return;
    }
    if (action == 'group' || action == 'contents') {
      final currentIds = members.map((book) => book.book.id).toSet();
      final choices = action == 'contents'
          ? members
          : widget.library.books
                .where((book) => !currentIds.contains(book.book.id))
                .toList();
      final selected = await showBookPanel<String>(
        context: context,
        child: Builder(
          builder: (context) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                action == 'contents'
                    ? 'Livros do grupo'
                    : 'Agrupar com outro livro',
                style: const TextStyle(fontFamily: 'Lora', fontSize: 22),
              ),
              const SizedBox(height: 16),
              if (choices.isEmpty)
                const Text(
                  'Baixe outro livro em Descobrir para criar um grupo.',
                ),
              for (final book in choices)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(book.book.title),
                  subtitle: Text(book.book.author),
                  onTap: () => Navigator.pop(context, book.book.id),
                ),
            ],
          ),
        ),
      );
      if (!mounted || selected == null) return;
      if (action == 'contents') {
        final book = widget.library.find(selected);
        if (book != null) await _actions(book);
      } else {
        await _mergeBooks(local.book.id, selected);
      }
      return;
    }
    try {
      if (action == 'desk') {
        await widget.library.setOnDesk(local.book.id, !local.onDesk);
      } else if (action == 'ungroup') {
        await widget.library.ungroupBook(local.book.id);
      } else if (action == 'delete') {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Excluir este livro?'),
            content: const Text(
              'O arquivo offline e a posição de leitura serão removidos deste dispositivo.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancelar'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Excluir'),
              ),
            ],
          ),
        );
        if (confirmed == true) await widget.library.remove(local.book.id);
      }
    } catch (_) {
      _message('Não foi possível salvar a alteração. Tente novamente.');
    }
  }

  Future<void> _mergeBooks(String first, String second) async {
    try {
      await widget.library.groupBooks(first, second);
    } catch (_) {
      _message('Não foi possível salvar o grupo. Tente novamente.');
    }
  }

  Widget _empty({required bool desk}) => Center(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              desk ? Icons.auto_stories_outlined : Icons.local_library_outlined,
              color: gold,
              size: 44,
            ),
            const SizedBox(height: 28),
            Text(
              desk
                  ? 'Um livro.\nUm momento seu.'
                  : 'Sua próxima história\ncomeça aqui.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineLarge,
            ),
            const SizedBox(height: 18),
            Text(
              desk
                  ? 'Escolha um livro para deixar sobre a mesa.\nO resto pode esperar.'
                  : 'Descubra e baixe um livro.\nDepois, leia mesmo sem conexão.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: muted, height: 1.6),
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: () => setState(
                () => _tab = desk && widget.library.books.isNotEmpty ? 1 : 2,
              ),
              icon: const Icon(Icons.arrow_forward, size: 18),
              label: Text(
                desk && widget.library.books.isNotEmpty
                    ? 'Abrir biblioteca'
                    : 'Descobrir livros',
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Future<double> _legacyReadingProgress(LocalBook local) async {
    final width = math.min(MediaQuery.sizeOf(context).width, 720.0) - 48;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final document = await EpubDocumentCache.load(local.bytes);
    final section = local.section.clamp(0, document.sections.length - 1);
    final offset = ReaderPagination.offsetForLegacyScroll(
      document.sections[section],
      scroll: local.scroll,
      width: width,
      textScaler: scaler,
      direction: direction,
    );
    var before = 0;
    var total = 0;
    for (var index = 0; index < document.sections.length; index++) {
      final length = document.sections[index].blocks.fold(
        0,
        (sum, block) => sum + (block.image == null ? block.text.length : 1),
      );
      if (index < section) before += length;
      total += length;
    }
    return total == 0 ? 0 : ((before + offset) / total).clamp(0.0, 1.0);
  }

  Widget _deskProgress(LocalBook local) {
    Widget label(double? progress, {bool failed = false}) => Text(
      failed
          ? 'Progresso indisponível'
          : progress == null
          ? 'Calculando leitura…'
          : '${(progress * 100).floor()}% lido',
      key: const ValueKey('desk-progress'),
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 12, color: Color(0xff929292)),
    );
    if (local.progress != null || (local.section == 0 && local.scroll == 0)) {
      return label(local.progress ?? 0);
    }
    return FutureBuilder<double>(
      future: _legacyProgress.putIfAbsent(
        local.book.id,
        () => _legacyReadingProgress(local),
      ),
      builder: (context, snapshot) =>
          label(snapshot.data, failed: snapshot.hasError),
    );
  }

  Widget _desk() {
    final books = widget.library.books.where((b) => b.onDesk).toList();
    if (books.isEmpty) return _empty(desk: true);
    final index = _deskIndex.clamp(0, books.length - 1);
    final local = books[index];
    if (!identical(_selectedBytes, local.bytes)) {
      _selectedBytes = local.bytes;
      _warmTimer?.cancel();
      _warmTimer = Timer(const Duration(milliseconds: 120), () {
        if (mounted) unawaited(EpubDocumentCache.warm(local.bytes));
      });
    }
    final topInset = MediaQuery.paddingOf(context).top;
    void changeBook(int direction) {
      if (books.length < 2) return;
      setState(() => _deskIndex = (index + direction) % books.length);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 600;
        final titleSize = wide ? 38.0 : 30.0;
        final authorSize = wide ? 20.0 : 18.0;
        final top = math.max(0.0, 72 - topInset);
        final textScaler = MediaQuery.textScalerOf(context);
        // Reserve space for text and breathing room; short screens can scroll.
        final bookHeight = math.min(
          700.0,
          math.min(
            (constraints.maxWidth - 48) * 1.4,
            math.max(
              340.0,
              constraints.maxHeight -
                  top -
                  textScaler.scale(titleSize) * 1.25 -
                  textScaler.scale(authorSize) * 1.4 -
                  textScaler.scale(12) * 1.5 -
                  96,
            ),
          ),
        );
        var swipeDistance = 0.0;
        return GestureDetector(
          excludeFromSemantics: true,
          onHorizontalDragStart: (_) => swipeDistance = 0,
          onHorizontalDragUpdate: (details) =>
              swipeDistance += details.delta.dx,
          onHorizontalDragEnd: (_) {
            if (swipeDistance.abs() >= 56) {
              changeBook(swipeDistance < 0 ? 1 : -1);
            }
          },
          child: SingleChildScrollView(
            child: ConstrainedBox(
              key: const ValueKey('desk-surface'),
              constraints: BoxConstraints(
                minWidth: constraints.maxWidth,
                minHeight: constraints.maxHeight,
              ),
              child: Padding(
                padding: EdgeInsets.fromLTRB(24, top, 24, 24),
                child: Column(
                  children: [
                    Text(
                      local.book.title,
                      key: const ValueKey('desk-title'),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Lora',
                        fontSize: titleSize,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                        color: paper,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      local.book.author,
                      key: const ValueKey('desk-author'),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: authorSize,
                        height: 1.4,
                        color: const Color(0xffc1b9a9),
                      ),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      key: const ValueKey('desk-cover'),
                      width: bookHeight / 1.4,
                      height: bookHeight,
                      child: DeskBook(
                        key: const ValueKey('desk-book'),
                        book: local.book,
                        bytes: local.coverBytes,
                        onOpen: () => _open(local),
                        onOpenWithOrigin: (origin) =>
                            _open(local, origin: origin),
                        onOrganize: () => _actions(local),
                        onBrowse: changeBook,
                      ),
                    ),
                    const SizedBox(height: 14),
                    _deskProgress(local),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _library() {
    final all = widget.library.books;
    final books = _filter == 0
        ? all
              .where(
                (b) => b.section > 0 || b.scroll > 0 || (b.progress ?? 0) > 0,
              )
              .toList()
        : all;
    final visibleIds = books.map((book) => book.book.id).toSet();
    final seen = <String>{};
    final groups = <List<LocalBook>>[];
    for (final book in books) {
      if (seen.contains(book.book.id)) continue;
      final group = widget.library
          .groupFor(book.book.id)
          .where((member) => visibleIds.contains(member.book.id))
          .toList();
      seen.addAll(group.map((member) => member.book.id));
      groups.add(group);
    }
    return CustomScrollView(
      key: const PageStorageKey('library-scroll'),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            24,
            math.max(0, 62 - MediaQuery.viewPaddingOf(context).top) + 12,
            24,
            0,
          ),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Biblioteca',
                  key: ValueKey('library-heading'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Lora',
                    fontSize: 26,
                    height: 33 / 26,
                    fontWeight: FontWeight.w600,
                    color: Color(0xfff5f5f5),
                  ),
                ),
                const SizedBox(height: 16),
                ShelfFilters(
                  key: const ValueKey('library-filters'),
                  labels: const ['Lendo', 'Baixados', 'Todos'],
                  selected: _filter,
                  onSelected: (value) => setState(() => _filter = value),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Toque no livro para ver ações · arraste para agrupar',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    height: 14 / 11,
                    color: Color(0xff929292),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
        if (all.isEmpty)
          SliverFillRemaining(hasScrollBody: false, child: _empty(desk: false))
        else ...[
          if (books.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Você ainda não começou uma leitura.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: muted),
                ),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            sliver: SliverShelf(
              itemCount: groups.length,
              itemHeight:
                  160 +
                  math.max(0, MediaQuery.textScalerOf(context).scale(12) - 12),
              itemBuilder: (context, index) => _libraryTile(groups[index]),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 18)),
      ],
    );
  }

  Widget _libraryTile(List<LocalBook> group) {
    final local = group.first;
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => !widget.library
          .groupFor(local.book.id)
          .any((member) => member.book.id == details.data),
      onAcceptWithDetails: (details) =>
          _mergeBooks(details.data, local.book.id),
      builder: (context, candidates, rejected) => LongPressDraggable<String>(
        data: local.book.id,
        feedback: Material(
          color: Colors.transparent,
          child: SizedBox(
            width: 92,
            height: 130,
            child: BookCover(
              book: local.book,
              bytes: local.coverBytes,
              thumbnail: true,
              framed: true,
            ),
          ),
        ),
        childWhenDragging: const Opacity(
          opacity: 0.3,
          child: SizedBox(width: 122, height: 160),
        ),
        child: Semantics(
          button: true,
          label:
              '${local.book.title}, ${local.book.author}${group.length > 1 ? ', grupo de ${group.length} livros' : ''}',
          hint:
              'Toque para ver ações. Mantenha pressionado e arraste sobre outro livro para agrupar.',
          child: Stack(
            key: ValueKey('library-book-${local.book.id}'),
            children: [
              if (candidates.isNotEmpty)
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: gold),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              for (
                var layer = math.min(2, group.length - 1);
                layer >= 0;
                layer--
              )
                Positioned(
                  left: 15 + layer * 5,
                  top: 2 + layer * 3,
                  width: 92,
                  height: 130,
                  child: InkWell(
                    key: layer == 0
                        ? ValueKey('library-cover-${local.book.id}')
                        : null,
                    onTap: () => _actions(local),
                    child: BookCover(
                      book: group[layer].book,
                      bytes: group[layer].coverBytes,
                      thumbnail: true,
                      framed: true,
                    ),
                  ),
                ),
              Positioned(
                left: 13,
                top: 137,
                width: 84,
                child: Text(
                  local.book.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 9,
                    height: 12 / 9,
                    color: Color(0xffbdbdbd),
                  ),
                ),
              ),
              Positioned(
                right: 0,
                top: 120,
                width: 32,
                height: 40,
                child: IconButton(
                  tooltip: 'Ações de ${local.book.title}',
                  onPressed: () => _actions(local),
                  padding: EdgeInsets.zero,
                  icon: const Icon(
                    Icons.more_horiz,
                    size: 18,
                    color: Color(0xffcacaca),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.library,
    builder: (context, _) => Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: _tab == 0 ? double.infinity : 860,
            ),
            child: Column(
              children: [
                Expanded(
                  child: IndexedStack(
                    index: _tab,
                    children: [
                      _desk(),
                      _library(),
                      DiscoverScreen(
                        active: _tab == 2,
                        library: widget.library,
                        catalog: widget.catalog,
                        catalogSettings: widget.catalogSettings,
                        onOpen: _open,
                        onLibrary: () => setState(() => _tab = 1),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 18),
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 382),
              child: SizedBox(
                height: 66,
                child: Row(
                  children: [
                    for (final (index, label) in [
                      'Sua Mesa',
                      'Biblioteca',
                      'Descobrir',
                    ].indexed)
                      Expanded(
                        child: Semantics(
                          selected: _tab == index,
                          button: true,
                          child: InkWell(
                            onTap: () => setState(() => _tab = index),
                            child: Center(
                              child: Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 16 / 12,
                                  fontWeight: _tab == index
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: _tab == index
                                      ? const Color(0xfff2f2f2)
                                      : const Color(0xff929292),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
