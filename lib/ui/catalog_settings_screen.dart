import 'package:flutter/material.dart';

import '../data/catalog.dart';
import '../data/catalog_settings.dart';
import '../data/catalog_sources.dart';

class CatalogSettingsScreen extends StatefulWidget {
  final CatalogSettings settings;
  final String activeCatalog;
  final CatalogSources? sources;

  const CatalogSettingsScreen({
    super.key,
    required this.settings,
    required this.activeCatalog,
    this.sources,
  });

  @override
  State<CatalogSettingsScreen> createState() => _CatalogSettingsScreenState();
}

class _CatalogSettingsScreenState extends State<CatalogSettingsScreen> {
  final _form = GlobalKey<FormState>();
  final _site = TextEditingController();
  final _accountForm = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = true;
  bool _loadFailed = false;
  bool _saving = false;
  String? _message;
  String? _accountMessage;
  bool _accountBusy = false;
  bool _loggingOut = false;

  bool get _approvedSite =>
      widget.settings.zLibrarySite == null ||
      widget.settings.zLibrarySite!.host == 'z-library.biz';

  bool get _canConnect =>
      !_loading &&
      !_loadFailed &&
      !_saving &&
      !_accountBusy &&
      _approvedSite &&
      widget.sources?.zLibrary.supported == true;

  @override
  void initState() {
    super.initState();
    widget.sources?.addListener(_sessionChanged);
    _load();
  }

  void _sessionChanged() {
    _accountMessage = null;
    _email.clear();
    _password.clear();
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant CatalogSettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sources != widget.sources) {
      oldWidget.sources?.removeListener(_sessionChanged);
      widget.sources?.addListener(_sessionChanged);
      _email.clear();
      _password.clear();
      _accountMessage = null;
    }
  }

  Future<void> _accountAction() async {
    final connector = widget.sources?.zLibrary;
    if (connector == null || _accountBusy || _saving) return;
    final logout = connector.isAuthenticated;
    if (!logout && (!_canConnect || !_accountForm.currentState!.validate())) {
      return;
    }
    final email = _email.text.trim();
    final password = _password.text;
    _password.clear();
    FocusScope.of(context).unfocus();
    setState(() {
      _accountBusy = true;
      _loggingOut = logout;
      _accountMessage = null;
    });
    try {
      if (logout) {
        _email.clear();
        await connector.logout();
      } else {
        await connector.login(email, password);
      }
      if (mounted) {
        _email.clear();
        setState(() {
          _accountMessage = logout
              ? 'Conta desconectada. Sua biblioteca foi preservada.'
              : 'Conta conectada para esta sess\u00e3o.';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _accountMessage = error is ApiException
              ? error.message
              : 'N\u00e3o foi poss\u00edvel conectar a conta. Tente novamente.';
        });
      }
    } finally {
      if (mounted) setState(() => _accountBusy = false);
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      await widget.settings.load();
      if (!mounted) return;
      _site.text = widget.settings.zLibrarySite?.toString() ?? '';
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save({bool remove = false}) async {
    if (_saving ||
        _accountBusy ||
        (!remove && !_form.currentState!.validate())) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      if (remove) {
        await widget.settings.removeZLibrarySite();
      } else {
        await widget.settings.saveZLibrarySite(_site.text);
      }
      if (!mounted) return;
      _site.text = widget.settings.zLibrarySite?.toString() ?? '';
      setState(() {
        _message = remove
            ? 'Endere\u00e7o removido deste dispositivo.'
            : widget.sources?.zLibrary.isAuthenticated == true
            ? 'Endere\u00e7o salvo neste dispositivo. A sess\u00e3o n\u00e3o foi alterada.'
            : 'Endere\u00e7o salvo neste dispositivo. A conta ainda n\u00e3o foi conectada.';
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _message =
              'N\u00e3o foi poss\u00edvel salvar. Verifique o armazenamento e tente novamente.';
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    widget.sources?.removeListener(_sessionChanged);
    _site.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_accountBusy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Fontes e contas')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Seu cat\u00e1logo',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.sources?.isZLibrary == true &&
                            !widget.sources!.zLibrary.isAuthenticated
                        ? 'Z-Library ativo para busca. Conecte a conta para baixar.'
                        : '${widget.sources?.displayName ?? widget.activeCatalog} continua ativo para busca e download.',
                  ),
                  const SizedBox(height: 24),
                  const Divider(),
                  const SizedBox(height: 24),
                  Text(
                    'Z-Library',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 12),
                  if (widget.sources == null) ...[
                    const Text(
                      'Integra\u00e7\u00e3o pendente',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Salve o endere\u00e7o do site onde criou sua conta. '
                      'Isso n\u00e3o conecta nem verifica a conta. '
                      'O login ser\u00e1 disponibilizado depois de validar o site '
                      'e implementar o m\u00e9todo de integra\u00e7\u00e3o.',
                    ),
                  ] else
                    const Text(
                      'Conector para https://z-library.biz. API n\u00e3o oficial, '
                      'sem garantia de disponibilidade. Acesse apenas obras autorizadas.',
                    ),
                  const SizedBox(height: 24),
                  if (_loading)
                    const Center(child: CircularProgressIndicator())
                  else if (_loadFailed) ...[
                    const Text(
                      'N\u00e3o foi poss\u00edvel abrir as configura\u00e7\u00f5es. '
                      'Sua biblioteca e o cat\u00e1logo continuam dispon\u00edveis. '
                      'Nenhum dado foi apagado.',
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: _load,
                      child: const Text('Tentar novamente'),
                    ),
                  ] else ...[
                    Form(
                      key: _form,
                      child: TextFormField(
                        key: const ValueKey('zlibrary-site'),
                        controller: _site,
                        enabled: !_saving && !_accountBusy,
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.done,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(
                          labelText: 'Endere\u00e7o do site',
                          helperText:
                              'Somente HTTPS, sem caminhos ou c\u00f3digos de acesso.',
                          helperMaxLines: 3,
                          errorMaxLines: 4,
                        ),
                        validator: (value) {
                          try {
                            CatalogSettings.parseSite(value ?? '');
                            return null;
                          } on FormatException catch (error) {
                            return error.message;
                          }
                        },
                        onFieldSubmitted: (_) => _save(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'N\u00e3o informe senha, cookies ou tokens aqui. '
                      'Apenas o endere\u00e7o \u00e9 salvo localmente; '
                      'salvar este campo n\u00e3o envia dados ao site.',
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _saving || _accountBusy ? null : () => _save(),
                      child: Text(
                        _saving ? 'Salvando...' : 'Salvar endere\u00e7o',
                      ),
                    ),
                    if (widget.settings.zLibrarySite != null) ...[
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: _saving || _accountBusy
                            ? null
                            : () => _save(remove: true),
                        child: const Text('Remover endere\u00e7o'),
                      ),
                    ],
                    if (_message != null) ...[
                      const SizedBox(height: 16),
                      Semantics(liveRegion: true, child: Text(_message!)),
                    ],
                  ],
                  if (widget.sources case final sources?) ...[
                    const SizedBox(height: 24),
                    const Divider(),
                    const SizedBox(height: 24),
                    Text(
                      'Fonte nesta sess\u00e3o',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    ListTile(
                      key: const ValueKey('catalog-primary'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(sources.primary.displayName),
                      selected: !sources.isZLibrary,
                      trailing: Icon(
                        !sources.isZLibrary
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                      ),
                      onTap: _accountBusy || _saving
                          ? null
                          : () => sources.selectZLibrary(false),
                    ),
                    ListTile(
                      key: const ValueKey('catalog-zlibrary'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Z-Library'),
                      subtitle: const Text(
                        'Busca sem conta; download exige login.',
                      ),
                      selected: sources.isZLibrary,
                      enabled: _canConnect,
                      trailing: Icon(
                        sources.isZLibrary
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                      ),
                      onTap: _canConnect
                          ? () => sources.selectZLibrary(true)
                          : null,
                    ),
                    if (!sources.zLibrary.supported)
                      const Text(
                        'Dispon\u00edvel na vers\u00e3o web pelo servidor local',
                      ),
                    if (!_approvedSite)
                      const Text(
                        'O conector s\u00f3 suporta o dom\u00ednio aprovado https://z-library.biz. '
                        'Salve esse endere\u00e7o ou remova o endere\u00e7o atual antes de selecionar ou conectar.',
                      ),
                    const SizedBox(height: 16),
                    const Text(
                      'Conta lembrada neste navegador por 30 dias, renovados ao abrir o app ou entrar em Descobrir. A senha n\u00e3o \u00e9 salva.',
                    ),
                    const SizedBox(height: 16),
                    if (sources.zLibrary.isAuthenticated) ...[
                      const Text('Conta conectada'),
                      const SizedBox(height: 16),
                      OutlinedButton(
                        onPressed: _accountBusy || _saving
                            ? null
                            : _accountAction,
                        child: Text(
                          _accountBusy ? 'Saindo...' : 'Sair da conta',
                        ),
                      ),
                    ] else if (sources.zLibrary.supported) ...[
                      const Text('Conta n\u00e3o conectada'),
                      const SizedBox(height: 16),
                      const Text(
                        'Ao conectar, o servidor local envia email e senha por HTTPS '
                        'somente para z-library.biz. A senha n\u00e3o \u00e9 salva. '
                        'A autoriza\u00e7\u00e3o da sess\u00e3o fica cifrada no servidor local. Se o servi\u00e7o revogar a sess\u00e3o, ser\u00e1 necess\u00e1rio conectar novamente.',
                      ),
                      const SizedBox(height: 16),
                      Form(
                        key: _accountForm,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TextFormField(
                              key: const ValueKey('zlibrary-email'),
                              controller: _email,
                              enabled: _canConnect,
                              keyboardType: TextInputType.emailAddress,
                              autocorrect: false,
                              enableSuggestions: false,
                              decoration: const InputDecoration(
                                labelText: 'Email',
                                errorMaxLines: 3,
                              ),
                              validator: (value) =>
                                  RegExp(
                                    r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
                                  ).hasMatch(value?.trim() ?? '')
                                  ? null
                                  : 'Informe um email v\u00e1lido.',
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              key: const ValueKey('zlibrary-password'),
                              controller: _password,
                              enabled: _canConnect,
                              obscureText: true,
                              autocorrect: false,
                              enableSuggestions: false,
                              enableIMEPersonalizedLearning: false,
                              decoration: const InputDecoration(
                                labelText: 'Senha',
                                errorMaxLines: 3,
                              ),
                              validator: (value) =>
                                  value == null || value.isEmpty
                                  ? 'Informe a senha.'
                                  : null,
                              onFieldSubmitted: (_) => _accountAction(),
                            ),
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: _canConnect ? _accountAction : null,
                              child: Text(
                                _accountBusy
                                    ? _loggingOut
                                          ? 'Saindo...'
                                          : 'Conectando...'
                                    : 'Conectar conta',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (_accountMessage != null) ...[
                      const SizedBox(height: 16),
                      Semantics(
                        liveRegion: true,
                        child: Text(_accountMessage!),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
