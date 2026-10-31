# Leitura Anywhere

**Uma biblioteca pessoal, um livro de cada vez.**

Aplicativo Flutter para organizar livros EPUB e ler com uma interface escura,
capas em destaque e uma mesa de leitura com livros em 3D. O projeto inclui
as plataformas web, Android e iOS e está em desenvolvimento.

## Recursos

- **Sua Mesa:** seleção de livros com capa, lombada, inclinação e abertura animada.
- **Biblioteca pessoal:** importação de EPUB sem DRM, identificação de duplicados
  por SHA-256 e armazenamento local.
- **Leitor:** sumário, navegação por seções, ajuste de fonte, temas escuro e sépia,
  seleção de texto e retomada da leitura.
- **Descobrir:** busca por título, autor ou assunto no Projeto Gutenberg via
  Gutendex, com categorias, paginação e download de EPUB.
- **Fonte adicional opcional:** conector Z-Library somente na versão web local,
  com uma ponte Node dedicada e sessão local cifrada.
- **Layout adaptável:** interface para celular e desktop, com fontes Lora e
  DM Sans incluídas no aplicativo.

## Requisitos

- Flutter estável com Dart >= 3.9, compatível com as dependências do projeto.
- Node.js >= 22 para o servidor web local e seus testes.
- Para Android: JDK 17 e Android SDK configurados para o Flutter.
- Para iOS: macOS, Xcode e configuração de assinatura apropriada.

Confira a instalação do Flutter com `flutter doctor`.

## Executar na Web

```sh
git clone https://github.com/lucashernandsz/leitura-anywhere.git
cd leitura-anywhere
flutter pub get
flutter build web
node tool/serve.mjs --port 8787
```

Abra **http://localhost:8787**. Encerre o servidor com `Ctrl+C`.

O servidor escuta apenas em `127.0.0.1`. Além dos arquivos do aplicativo, oferece
a ponte de mesma origem necessária para catálogo, capas e downloads no navegador.
**Não exponha esse servidor na internet.**

`flutter run -d chrome` permite executar a interface, mas não inclui essa ponte.
Para usar o catálogo web completo, prefira o comando Node acima.

## Android e iOS

Com um dispositivo ou emulador configurado:

```sh
flutter pub get
flutter devices
flutter run -d <id-do-dispositivo>
```

Para gerar um APK:

```sh
flutter build apk --release
```

O arquivo será gerado em `build/app/outputs/flutter-apk/app-release.apk`.
**O release Android ainda usa assinatura de debug.** Configure uma chave própria
antes de distribuir uma versão oficial. Não adicione chaves de assinatura ao Git.

No macOS, o projeto iOS pode ser compilado sem assinatura para verificação:

```sh
flutter build ios --no-codesign
```

O conector Z-Library depende do servidor web local e não está disponível nos
builds nativos. A existência dos projetos Android e iOS não comprova validação
em dispositivos nem publicação nas lojas.

## Dados e Privacidade

- Livros e posição de leitura ficam no dispositivo; não há sincronização entre
  dispositivos.
- Na web, a biblioteca usa IndexedDB. Limpar os dados do site pode remove-la.
  Livros podem ser lidos sem rede com o aplicativo já aberto; reabrir o site
  offline não é garantido.
- O conector opcional recebe a senha apenas durante o login. A ponte mantém
  identificadores de sessão cifrados em `.local/zlibrary/`, fora do build e do Git.
- EPUBs são tratados como dados não confiáveis: há validação de ZIP, limites de
  tamanho e conversão de HTML em widgets, sem executar scripts ou usar WebView.
- Este repositório não inclui livros, contas, sessões ou credenciais pessoais.

## Limites Atuais

- Importação de **EPUB sem DRM, até 40 MiB**. PDF não é suportado.
- O leitor não reproduz integralmente CSS editorial, tabelas complexas ou notas
  interativas. EPUBs refluíveis não possuem paginação editorial fixa.
- O conector Z-Library usa uma interface não oficial, pode ficar indisponível e
  não contorna verificações, permissões ou cotas do provedor.
- Use somente obras cujo acesso e uso sejam autorizados. O filtro de domínio
  público do Gutenberg refere-se aos Estados Unidos; confira os direitos no seu país.

## Testes

```sh
flutter analyze
flutter test
node --test tool/serve.test.mjs tool/zlibrary.test.mjs tool/zlibrary_session_store.test.mjs
```

O teste de catálogo com rede real é opcional:

```sh
flutter test test/catalog_live_test.dart --dart-define=LIVE_BOOK_TEST=true
```

## Estrutura

```text
lib/data/       Catálogos, modelos e armazenamento local
lib/reader/     Validação de EPUB, paginação e leitura
lib/ui/         Mesa, biblioteca, capas e descoberta
test/          Testes Flutter
tool/          Servidor local, conectores e testes Node
assets/fonts/  Fontes e respectivas licenças
android/       Projeto Android
ios/           Projeto iOS
web/           Configuração web
```

As fontes Lora e DM Sans usam a SIL Open Font License 1.1; as licenças acompanham
os arquivos em [`assets/fonts/`](assets/fonts/).

Detalhes de arquitetura, segurança e histórico de validações estão nas
[notas de desenvolvimento](docs/DEVELOPMENT.md).
