import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'book.dart';

// The local web server restricts this proxy to explicitly allowed book hosts.
// Mobile clients download directly; browsers need a same-origin CORS bridge.
Uri catalogTransportUri(Uri uri) {
  if (!kIsWeb) return uri;
  return Uri.base
      .resolve(
        zlibraryCoverUri(uri.toString()) != null
            ? '/api/zlibrary/cover'
            : '/api/proxy',
      )
      .replace(queryParameters: {'url': uri.toString()});
}

/// Matches only the public cover CDN and paths verified by the local bridge.
Uri? zlibraryCoverUri(Object? value) {
  if (value is! String ||
      value.length > 8192 ||
      RegExp(r'[\\\x00-\x20\x7f]').hasMatch(value) ||
      RegExp(r'^https://[^/?#]*@').hasMatch(value) ||
      !value.startsWith('https://')) {
    return null;
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.host != 's3proxy-alp2-covers.cdn-zlib.sk' ||
      uri.userInfo.isNotEmpty ||
      uri.port != 443 ||
      uri.hasQuery ||
      uri.hasFragment ||
      !RegExp(
        r'^/covers\d*/[a-zA-Z0-9/_-]+\.(?:jpe?g|png|webp)$',
      ).hasMatch(uri.path)) {
    return null;
  }
  return uri;
}

class ApiException implements Exception {
  final String message;
  final int? statusCode;

  const ApiException(this.message, {this.statusCode});

  @override
  String toString() =>
      statusCode == null ? message : '$message (HTTP $statusCode)';
}

class CatalogPage {
  final List<Book> books;
  final bool hasNext;
  final int page;

  CatalogPage({
    required List<Book> books,
    required this.hasNext,
    required this.page,
  }) : books = List<Book>.unmodifiable(books);
}

/// Provider boundary: authentication and source-specific IDs belong in adapters,
/// not in the discovery UI or the local EPUB library.
abstract interface class BookCatalog {
  String get displayName;
  String get usageNotice;

  Future<CatalogPage> search({String query = '', String? topic, int page = 1});
  Future<Uint8List> download(Book book, {void Function(double?)? onProgress});
  void dispose();
}

/// Generic Gutendex adapter, not a scraper or a Z-Library integration.
/// Custom HTTPS endpoints must expose the same query/JSON contract, including
/// Gutenberg IDs. BOOK_CATALOG_NAME labels that endpoint's source.
/// Gutenberg public-domain status refers to the US, not a universal license.
class CatalogService implements BookCatalog {
  final Duration _timeout;
  static const _maxCatalogBytes = 4 * 1024 * 1024;
  static const _configuredUrl = String.fromEnvironment('BOOK_CATALOG_URL');
  static const _configuredName = String.fromEnvironment(
    'BOOK_CATALOG_NAME',
    defaultValue: 'Cat\u00e1logo personalizado',
  );

  final http.Client _client;
  final bool _ownsClient;
  final Uri _endpoint;
  final String _source;
  bool _disposed = false;

  CatalogService({
    http.Client? client,
    Uri? endpoint,
    Duration timeout = const Duration(seconds: 50),
  }) : _timeout = timeout,
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _endpoint =
           endpoint ??
           Uri.parse(
             _configuredUrl.isEmpty
                 ? 'https://gutendex.com/books/'
                 : _configuredUrl,
           ),
       _source = endpoint != null || _configuredUrl.isNotEmpty
           ? _configuredName
           : 'Projeto Gutenberg' {
    if (!isSecureBookUri(_endpoint)) {
      if (_ownsClient) _client.close();
      throw const ApiException('O catalogo exige URL HTTPS sem credenciais.');
    }
  }

  @override
  String get displayName => _source;

  @override
  String get usageNotice =>
      'Confira os direitos de uso no seu pa\u00eds antes de baixar. '
      'O filtro de dom\u00ednio p\u00fablico deste cat\u00e1logo se refere aos Estados Unidos.';

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_ownsClient) _client.close();
  }

  @override
  Future<CatalogPage> search({
    String query = '',
    String? topic,
    int page = 1,
  }) async {
    if (page < 1) throw ArgumentError.value(page, 'page', 'Use pagina >= 1.');
    final params = Map<String, String>.from(_endpoint.queryParameters)
      ..remove('search')
      ..remove('topic')
      ..addAll({
        'languages': 'pt',
        'mime_type': 'application/epub+zip',
        'copyright': 'false',
        'page': '$page',
      });
    if (query.trim().isNotEmpty) params['search'] = query.trim();
    if (topic != null && topic.trim().isNotEmpty) {
      params['topic'] = topic.trim();
    }
    try {
      final response = await _get(
        _endpoint.replace(queryParameters: params),
        accept: 'application/json',
      );
      final bytes = await _read(response, _maxCatalogBytes);
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map ||
          decoded['results'] is! List ||
          (decoded['next'] != null && decoded['next'] is! String)) {
        throw const FormatException('Resposta Gutendex invalida.');
      }
      final books = <Book>[];
      for (final item in decoded['results'] as List) {
        if (item is! Map) throw const FormatException('Livro invalido.');
        books.add(_parseBook(Map<String, dynamic>.from(item)));
      }
      return CatalogPage(
        books: books,
        hasNext: decoded['next'] != null,
        page: page,
      );
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const ApiException('Tempo esgotado ao consultar o catalogo.');
    } on FormatException {
      throw const ApiException('O catalogo retornou dados invalidos.');
    } catch (_) {
      throw const ApiException('Nao foi possivel consultar o catalogo.');
    }
  }

  Book _parseBook(Map<String, dynamic> item) {
    final id = item['id'];
    final title = item['title'];
    final authors = item['authors'];
    final formats = item['formats'];
    final subjects = item['subjects'] ?? const <String>[];
    if (id is! int ||
        id < 1 ||
        title is! String ||
        title.trim().isEmpty ||
        authors is! List ||
        formats is! Map ||
        subjects is! List ||
        subjects.any((value) => value is! String)) {
      throw const FormatException('Livro Gutendex invalido.');
    }
    final names = <String>[];
    for (final author in authors) {
      if (author is! Map || author['name'] is! String) {
        throw const FormatException('Autor Gutendex invalido.');
      }
      final name = (author['name'] as String).trim();
      if (name.isNotEmpty) names.add(name);
    }
    String? secureUrl(dynamic value) {
      if (value is! String) return null;
      final uri = Uri.tryParse(value);
      return uri != null && isSecureBookUri(uri) ? uri.toString() : null;
    }

    return Book(
      id: 'gutenberg:$id',
      title: title,
      author: names.isEmpty ? 'Autor desconhecido' : names.join(', '),
      source: _source,
      coverUrl: secureUrl(formats['image/jpeg']),
      downloadUrl: secureUrl(formats['application/epub+zip']),
      subjects: List<String>.from(subjects),
    );
  }

  @override
  Future<Uint8List> download(
    Book book, {
    void Function(double?)? onProgress,
  }) async {
    if (!book.downloadable) {
      throw const ApiException('Livro sem URL HTTPS para download EPUB.');
    }
    try {
      final response = await _get(
        Uri.parse(book.downloadUrl!),
        accept: 'application/epub+zip',
      );
      final bytes = await _read(response, maxBookBytes, onProgress: onProgress);
      validateBookBytes(bytes);
      onProgress?.call(1);
      return bytes;
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const ApiException('Tempo esgotado ao baixar o EPUB.');
    } on FormatException catch (error) {
      throw ApiException(error.message);
    } catch (_) {
      throw const ApiException('Nao foi possivel baixar o EPUB.');
    }
  }

  Future<http.StreamedResponse> _get(Uri uri, {required String accept}) async {
    if (_disposed) throw const ApiException('Servico de catalogo encerrado.');
    for (var redirects = 0; ; redirects++) {
      if (!isSecureBookUri(uri)) {
        throw const ApiException('URL insegura: use HTTPS sem credenciais.');
      }
      final request =
          http.Request('GET', catalogTransportUri(uri.replace(fragment: '')))
            ..followRedirects = false
            ..maxRedirects = 0
            ..headers['Accept'] = accept;
      final response = await _client.send(request).timeout(_timeout);
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        await response.stream.listen(null).cancel();
        if (redirects >= 3) {
          throw const ApiException('Limite de 3 redirecionamentos excedido.');
        }
        final location = response.headers['location'];
        if (location == null || location.trim().isEmpty) {
          throw const ApiException('Redirecionamento sem destino valido.');
        }
        final target = Uri.tryParse(location);
        if (target == null) {
          throw const ApiException('Redirecionamento com URL invalida.');
        }
        uri = uri.resolveUri(target);
        continue;
      }
      if (response.statusCode != 200) {
        await response.stream.listen(null).cancel();
        throw ApiException(
          'Falha na requisicao ao catalogo/EPUB.',
          statusCode: response.statusCode,
        );
      }
      return response;
    }
  }

  Future<Uint8List> _read(
    http.StreamedResponse response,
    int limit, {
    void Function(double?)? onProgress,
  }) async {
    final length = response.contentLength;
    if (length != null && length > limit) {
      await response.stream.listen(null).cancel();
      throw ApiException(
        limit == maxBookBytes
            ? 'O EPUB excede o limite de 40 MiB.'
            : 'Resposta do catalogo excede o limite permitido.',
      );
    }
    final builder = BytesBuilder(copy: false);
    onProgress?.call(length != null && length > 0 ? 0 : null);
    await for (final chunk in response.stream.timeout(_timeout)) {
      if (builder.length + chunk.length > limit) {
        throw ApiException(
          limit == maxBookBytes
              ? 'O EPUB excede o limite de 40 MiB.'
              : 'Resposta do catalogo excede o limite permitido.',
        );
      }
      builder.add(chunk);
      onProgress?.call(
        length != null && length > 0
            ? (builder.length / length).clamp(0.0, 1.0).toDouble()
            : null,
      );
    }
    if (length != null && builder.length != length) {
      throw const ApiException(
        'Download incompleto: tamanho recebido diverge.',
      );
    }
    return builder.takeBytes();
  }
}
