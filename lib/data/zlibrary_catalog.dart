import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'book.dart';
import 'catalog.dart';
import 'catalog_settings.dart';

/// Uses only the dedicated loopback bridge, never the public book proxy.
/// The session stays in memory and can be restored through an HttpOnly cookie.
/// Without settings, logout cannot prevent restoration by a new instance.
class ZLibraryCatalog extends ChangeNotifier implements BookCatalog {
  final http.Client _client;
  final bool _ownsClient;
  final Uri? _endpoint;
  final Duration _timeout;
  final CatalogSettings? _settings;
  String? _session;
  String? _rememberedSession;
  Future<bool>? _restoration;
  Timer? _expiry;
  final _requests = <Completer<void>>{};
  int _generation = 0;
  bool _disposed = false;
  bool _restorationBlocked = false;

  ZLibraryCatalog({
    http.Client? client,
    Uri? endpoint,
    CatalogSettings? settings,
    Duration timeout = const Duration(seconds: 50),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _settings = settings,
       _timeout = timeout,
       _endpoint = endpoint ?? _localEndpoint() {
    final uri = _endpoint;
    if (uri != null &&
        (uri.scheme != 'http' ||
            !const ['localhost', '127.0.0.1', '::1'].contains(uri.host) ||
            uri.userInfo.isNotEmpty ||
            uri.hasQuery ||
            uri.hasFragment ||
            uri.path != '/api/zlibrary/')) {
      if (_ownsClient) _client.close();
      throw const ApiException('O conector exige o servidor web local.');
    }
  }

  static Uri? _localEndpoint() {
    if (!kIsWeb ||
        Uri.base.scheme != 'http' ||
        !const ['localhost', '127.0.0.1', '::1'].contains(Uri.base.host)) {
      return null;
    }
    return Uri.base.resolve('/api/zlibrary/');
  }

  bool get supported => _endpoint != null;
  bool get isAuthenticated => _session != null;

  @override
  String get displayName => 'Z-Library';

  @override
  String get usageNotice =>
      'Baixe somente obras que voc\u00ea tem direito de acessar. '
      'A disponibilidade no cat\u00e1logo n\u00e3o comprova permiss\u00e3o de uso. '
      'Downloads exigem conta e respeitam os limites do servi\u00e7o.';

  Future<bool> restoreSession({bool renew = false}) {
    if (!supported || _disposed || _restorationBlocked) {
      return Future.value(false);
    }
    final pending = _restoration;
    if (pending != null) return pending;
    if (isAuthenticated && !renew) return Future.value(true);
    final restoration = _restoreSession();
    _restoration = restoration;
    return restoration.whenComplete(() {
      if (identical(_restoration, restoration)) _restoration = null;
    });
  }

  Future<bool> _restoreSession() async {
    final generation = ++_generation;
    try {
      final settings = _settings;
      if (settings != null && !await settings.canRestoreZLibrarySession()) {
        return false;
      }
      if (_disposed || _restorationBlocked || generation != _generation) {
        return false;
      }
      final result = await _json('session', {});
      final session = result['session'];
      final seconds = result['expiresIn'];
      if (session is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(session) ||
          seconds is! int ||
          seconds < 1 ||
          seconds > 1800 ||
          _disposed ||
          generation != _generation) {
        return false;
      }
      final changed = _session != session;
      _session = session;
      _rememberedSession = session;
      _expiry?.cancel();
      _expiry = Timer(
        Duration(seconds: seconds),
        () => _clearSession(expired: true),
      );
      if (changed) notifyListeners();
      return true;
    } catch (_) {
      // An absent/expired session or offline bridge must not block the library.
      return false;
    }
  }

  Future<void> login(String email, String password) async {
    if (_disposed) throw const ApiException('Conector encerrado.');
    if (isAuthenticated) {
      throw const ApiException(
        'Encerre a sess\u00e3o antes de conectar outra conta.',
      );
    }
    final generation = ++_generation;
    _restoration = null;
    _restorationBlocked = true;
    final result = await _json('login', {
      'email': email.trim(),
      'password': password,
    });
    final session = result['session'];
    if (session is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(session)) {
      throw const ApiException(
        'Resposta de autentica\u00e7\u00e3o inv\u00e1lida.',
      );
    }
    var accepted = false;
    try {
      if (_disposed || generation != _generation) return;
      final settings = _settings;
      if (settings != null) {
        try {
          await settings.setZLibrarySessionRestoration(true);
        } catch (_) {
          throw const ApiException(
            'Nao foi possivel salvar a permissao de restauracao. Tente novamente.',
          );
        }
      }
      if (_disposed || generation != _generation) return;
      _session = session;
      _rememberedSession = session;
      _restorationBlocked = false;
      _expiry?.cancel();
      _expiry = Timer(
        const Duration(minutes: 30),
        () => _clearSession(expired: true),
      );
      accepted = true;
      notifyListeners();
    } finally {
      if (!accepted) {
        try {
          await _json('logout', {}, token: session);
        } catch (_) {
          // The persisted opt-out still prevents restoration if revocation fails.
        }
      }
    }
  }

  void _clearSession({bool forget = false, bool expired = false}) {
    // Expiry ends access, but an authorized renewal may still be in flight.
    if (!expired) {
      _generation++;
      _restoration = null;
    }
    _expiry?.cancel();
    _expiry = null;
    final changed = _session != null;
    _session = null;
    if (forget) _rememberedSession = null;
    if (changed && !_disposed) notifyListeners();
  }

  Future<void> logout() async {
    final token = _session ?? _rememberedSession;
    final generation = ++_generation;
    _restoration = null;
    _restorationBlocked = true;
    final settings = _settings;
    if (settings != null) {
      try {
        await settings.setZLibrarySessionRestoration(false);
      } catch (_) {
        throw const ApiException(
          'Nao foi possivel salvar a saida da conta. Tente sair novamente antes de fechar o aplicativo.',
        );
      }
    }
    if (generation == _generation) _clearSession(forget: true);
    if (token == null) return;
    try {
      await _json('logout', {}, token: token);
    } catch (_) {
      // Persisted intent also protects new instances when settings are provided.
    }
  }

  @override
  Future<CatalogPage> search({
    String query = '',
    String? topic,
    int page = 1,
  }) async {
    if (page < 1) throw ArgumentError.value(page, 'page');
    if (query.trim().isEmpty) {
      return CatalogPage(books: [], hasNext: false, page: page);
    }
    final result = await _json('search', {'query': query.trim(), 'page': page});
    final items = result['books'];
    if (items is! List || result['hasNext'] is! bool) {
      throw const ApiException('Resposta do cat\u00e1logo inv\u00e1lida.');
    }
    final books = <Book>[];
    for (final item in items) {
      if (item is! Map ||
          item['id'] is! int ||
          (item['id'] as int) < 1 ||
          item['hash'] is! String ||
          !RegExp(r'^[A-Za-z0-9]{1,64}$').hasMatch(item['hash'] as String) ||
          item['extension'] != 'epub' ||
          item['title'] is! String ||
          (item['title'] as String).trim().isEmpty ||
          item['author'] is! String) {
        throw const ApiException('Metadados do cat\u00e1logo inv\u00e1lidos.');
      }
      final id = item['id'];
      final hash = item['hash'];
      books.add(
        Book(
          id: 'zlibrary:$id:$hash',
          title: item['title'] as String,
          author: (item['author'] as String).trim().isEmpty
              ? 'Autor desconhecido'
              : item['author'] as String,
          source: displayName,
          coverUrl: zlibraryCoverUri(item['coverUrl'])?.toString(),
          downloadUrl: 'https://z-library.biz/eapi/book/$id/$hash/file',
        ),
      );
    }
    return CatalogPage(
      books: books,
      hasNext: result['hasNext'] as bool,
      page: page,
    );
  }

  @override
  Future<Uint8List> download(
    Book book, {
    void Function(double?)? onProgress,
  }) async {
    final match = RegExp(
      r'^zlibrary:([1-9][0-9]*):([A-Za-z0-9]{1,64})$',
    ).firstMatch(book.id);
    if (match == null ||
        book.downloadUrl !=
            'https://z-library.biz/eapi/book/${match[1]}/${match[2]}/file') {
      throw const ApiException('Identidade de livro inv\u00e1lida.');
    }
    if (_session == null &&
        _rememberedSession != null &&
        !_restorationBlocked) {
      await restoreSession();
    }
    final token = _session;
    if (token == null || _restorationBlocked) {
      throw const ApiException(
        'Conecte sua conta em Fontes e contas para baixar.',
      );
    }
    final bytes = await _post(
      'download',
      {'id': int.parse(match[1]!), 'hash': match[2]},
      token: token,
      binary: true,
      onProgress: onProgress,
    );
    if (_disposed || _restorationBlocked || token != _session) {
      throw const ApiException(
        'Sess\u00e3o encerrada. Conecte sua conta novamente.',
      );
    }
    validateBookBytes(bytes);
    onProgress?.call(1);
    return bytes;
  }

  Future<Map<String, dynamic>> _json(
    String operation,
    Map<String, dynamic> body, {
    String? token,
  }) async {
    final bytes = await _post(operation, body, token: token);
    try {
      final value = jsonDecode(utf8.decode(bytes));
      if (value is Map<String, dynamic>) return value;
    } catch (_) {
      // Never display raw server responses: they may contain sensitive data.
    }
    throw const ApiException('Resposta do conector inv\u00e1lida.');
  }

  Future<Uint8List> _post(
    String operation,
    Map<String, dynamic> body, {
    String? token,
    bool binary = false,
    void Function(double?)? onProgress,
  }) async {
    if (_disposed) throw const ApiException('Conector encerrado.');
    final endpoint = _endpoint;
    if (endpoint == null) {
      throw const ApiException(
        'Z-Library exige a vers\u00e3o web no servidor local nesta etapa.',
      );
    }
    final abort = Completer<void>();
    final generation = _generation;
    _requests.add(abort);
    final request =
        http.AbortableRequest(
            'POST',
            endpoint.resolve(operation),
            abortTrigger: abort.future,
          )
          ..followRedirects = false
          ..headers.addAll({
            'Content-Type': 'application/json; charset=utf-8',
            'X-Leitura-Client': '1',
            if (token != null) 'Authorization': 'Bearer $token',
          })
          ..body = jsonEncode(body);
    Future<Uint8List> run() async {
      final response = await _client.send(request);
      if (abort.isCompleted) {
        await response.stream.listen(null).cancel();
        throw const ApiException('Opera\u00e7\u00e3o encerrada.');
      }
      final success = response.statusCode == 200;
      if (response.statusCode == 401 &&
          ((token != null &&
                  (token == _session || token == _rememberedSession)) ||
              (operation == 'session' && generation == _generation))) {
        _clearSession(forget: true);
      }
      final type = response.headers['content-type']?.split(';').first.trim();
      final limit = success && binary ? maxBookBytes : 4 * 1024 * 1024;
      final length = response.contentLength;
      if (length != null && length > limit) {
        await response.stream.listen(null).cancel();
        throw const ApiException('Resposta excede o limite permitido.');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        if (abort.isCompleted) {
          throw const ApiException('Opera\u00e7\u00e3o encerrada.');
        }
        if (builder.length + chunk.length > limit) {
          throw const ApiException('Resposta excede o limite permitido.');
        }
        builder.add(chunk);
        if (success && binary) {
          onProgress?.call(
            length != null && length > 0
                ? (builder.length / length).clamp(0, 1).toDouble()
                : null,
          );
        }
      }
      final bytes = builder.takeBytes();
      if (length != null && bytes.length != length) {
        throw const ApiException('Resposta incompleta do conector.');
      }
      if (!success) {
        String? code;
        try {
          final error = jsonDecode(utf8.decode(bytes));
          if (error is Map && error['code'] is String) {
            code = error['code'] as String;
          }
        } catch (_) {}
        throw ApiException(switch (code) {
          'AUTH_REQUIRED' =>
            'Conta n\u00e3o conectada ou sess\u00e3o expirada. Conecte novamente.',
          'DOWNLOAD_DENIED' =>
            'O servi\u00e7o n\u00e3o permitiu este download. Confira permiss\u00f5es e cota.',
          'HOST_NOT_ALLOWED' =>
            'O destino do arquivo ainda n\u00e3o foi aprovado pelo conector.',
          'RATE_LIMITED' =>
            'Muitas tentativas. Aguarde um minuto antes de tentar novamente.',
          'TOO_LARGE' => 'O conte\u00fado excede o limite permitido.',
          'TIMEOUT' => 'Tempo esgotado ao consultar Z-Library.',
          _ =>
            'N\u00e3o foi poss\u00edvel concluir a opera\u00e7\u00e3o no Z-Library. Tente mais tarde.',
        });
      }
      if (type != (binary ? 'application/epub+zip' : 'application/json')) {
        throw const ApiException(
          'Resposta inesperada. Verifique o servidor local e tente novamente.',
        );
      }
      return bytes;
    }

    try {
      return await run().timeout(_timeout);
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const ApiException('Tempo esgotado ao consultar Z-Library.');
    } catch (_) {
      throw const ApiException(
        'N\u00e3o foi poss\u00edvel acessar o conector local.',
      );
    } finally {
      _requests.remove(abort);
      if (!abort.isCompleted) abort.complete();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _clearSession(forget: true);
    for (final request in _requests) {
      if (!request.isCompleted) request.complete();
    }
    if (_ownsClient) _client.close();
    super.dispose();
  }
}
