import 'package:hive/hive.dart';

/// Non-secret configuration only. Never store passwords, cookies or tokens here.
class CatalogSettings {
  static const _siteKey = 'zLibrarySite';
  static const _restoreKey = 'zLibrarySessionRestorationAllowed';
  Box<dynamic>? _box;
  final Future<Box<dynamic>> Function()? _openBox;
  Future<void> _restorationWrites = Future<void>.value();
  int _restorationRevision = 0;
  bool? _restorationAllowed;

  CatalogSettings(Box<dynamic> box) : _box = box, _openBox = null;

  CatalogSettings.lazy(Future<Box<dynamic>> Function() openBox)
    : _openBox = openBox;

  Future<void> load() async {
    if (_box?.isOpen == true) return;
    final openBox = _openBox;
    if (openBox == null) throw StateError('Armazenamento indisponivel.');
    _box = await openBox();
  }

  /// Missing, unreadable or unconfirmed storage never authorizes restoration.
  Future<bool> canRestoreZLibrarySession() async {
    if (_restorationAllowed == false) return false;
    try {
      await load();
      return _restorationAllowed != false && _box!.get(_restoreKey) == true;
    } catch (_) {
      return false;
    }
  }

  /// Serializes intent changes, including while lazy storage is opening.
  Future<void> setZLibrarySessionRestoration(bool allowed) {
    final revision = ++_restorationRevision;
    _restorationAllowed = false;
    final write = _restorationWrites.then((_) async {
      await load();
      await _box!.put(_restoreKey, allowed);
      await _box!.flush();
      if (revision == _restorationRevision) _restorationAllowed = allowed;
    });
    // A failed write must not prevent a later logout or explicit login retry.
    _restorationWrites = write.then<void>((_) {}, onError: (Object _) {});
    return write;
  }

  static Uri parseSite(String value) {
    final uri = Uri.tryParse(value.trim());
    if (value.contains('@') ||
        uri == null ||
        uri.scheme != 'https' ||
        !uri.hasAuthority ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.authority.contains('@') ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.host.length > 253 ||
        !uri.host.contains('.') ||
        !uri.host
            .split('.')
            .every(
              (label) => RegExp(
                r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$',
              ).hasMatch(label),
            )) {
      throw const FormatException(
        'Use somente o endere\u00e7o HTTPS do site, sem login, caminhos ou c\u00f3digos.',
      );
    }
    return Uri(scheme: 'https', host: uri.host);
  }

  Uri? get zLibrarySite {
    final value = _box?.isOpen == true ? _box!.get(_siteKey) : null;
    if (value is! String) return null;
    try {
      return parseSite(value);
    } on FormatException {
      // Invalid persisted configuration must never become a network destination.
      return null;
    }
  }

  Future<void> saveZLibrarySite(String value) async {
    final site = parseSite(value);
    await load();
    await _box!.put(_siteKey, site.toString());
  }

  Future<void> removeZLibrarySite() async {
    await load();
    await _box!.delete(_siteKey);
  }
}
