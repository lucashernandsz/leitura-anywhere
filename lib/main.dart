import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'app.dart';
import 'data/catalog.dart';
import 'data/catalog_settings.dart';
import 'data/catalog_sources.dart';
import 'data/library.dart';
import 'data/zlibrary_catalog.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xff080808),
    ),
  );
  runApp(const Bootstrap());
}

class Bootstrap extends StatefulWidget {
  const Bootstrap({super.key});

  @override
  State<Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<Bootstrap> {
  Library? _library;
  CatalogSources? _catalog;
  CatalogSettings? _catalogSettings;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() => _error = null);
    try {
      await Hive.initFlutter();
      final box = await Hive.openBox<dynamic>('leitura_library_v1');
      final library = Library(box);
      await library.load();
      final settings = CatalogSettings.lazy(
        () => Hive.openBox<dynamic>('leitura_catalog_settings_v1'),
      );
      final catalog = CatalogSources(
        primary: CatalogService(),
        zLibrary: ZLibraryCatalog(settings: settings),
      );
      if (!mounted) {
        library.dispose();
        catalog.dispose();
        return;
      }
      setState(() {
        _library = library;
        _catalog = catalog;
        _catalogSettings = settings;
      });
      unawaited(_restoreAccount(catalog, settings));
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Não foi possível abrir a biblioteca. Seus dados não foram apagados. '
              'Verifique o armazenamento disponível e tente novamente.',
        );
      }
    }
  }

  Future<void> _restoreAccount(
    CatalogSources catalog,
    CatalogSettings settings,
  ) async {
    final selectionRevision = catalog.selectionRevision;
    try {
      await settings.load();
      final site = settings.zLibrarySite;
      if (!mounted ||
          selectionRevision != catalog.selectionRevision ||
          (site != null && site.host != 'z-library.biz')) {
        return;
      }
      await catalog.restoreSession();
    } catch (_) {
      // Account recovery never delays startup or prevents offline reading.
    }
  }

  @override
  void dispose() {
    _library?.dispose();
    _catalog?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_library != null) {
      return LeituraApp(
        library: _library!,
        catalog: _catalog!,
        catalogSettings: _catalogSettings!,
      );
    }
    return MaterialApp(
      theme: leituraTheme,
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: _error == null
                ? const CircularProgressIndicator()
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: _start,
                        child: const Text('Tentar novamente'),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
