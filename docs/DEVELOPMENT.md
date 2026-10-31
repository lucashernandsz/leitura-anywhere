# Notas de Desenvolvimento

Registro técnico e histórico do Leitura Anywhere. As validações abaixo pertencem
às datas indicadas e não substituem uma nova execução dos testes. Para instalar
e executar o projeto, consulte o [README](../README.md).

Aplicação Flutter baseada no `.pen` do projeto: interface escura, títulos Lora,
texto DM Sans, capas em destaque e navegação Sua Mesa / Biblioteca / Descobrir.
Não usa Dende. O arquivo de design permanece intacto.

## Recursos

- Busca por título, autor e assunto, categorias e paginação.
- Download de EPUB, validação e biblioteca persistida localmente.
- Z-Library na versão web local: busca pública, seleção de fonte e formulário
  de conta com sessão lembrada e renovada automaticamente neste navegador.
  Download, importação e abertura de Dom Casmurro validados com a conta conectada.
- Importação de EPUB pelo seletor de arquivos, com deduplicação por SHA-256.
- Sua Mesa com seleção de livro, leitura e organização da biblioteca.
- Livro com volume 3D na Sua Mesa: capa, lombada, contracapa e bordas de páginas.
  Deslize para os lados com mouse ou toque para trocar de livro, sem contador ou
  setas visíveis. Arraste na vertical para inclinar; toque para ler e mantenha
  pressionado para organizar. Com foco no livro, use as setas laterais para
  trocar de livro, as verticais para inclinar, Home para restaurar e Enter/Espaço
  para ler. O botão Restaurar rotação também retorna à posição inicial.
  A rotação acompanha o gesto, sem animação automática ou inércia. Contracapa e
  lombada usam acabamento ilustrativo, não imagens editoriais extraídas do EPUB.
- Leitor offline: sumário, navegação por seções, texto selecionável, ajuste de
  fonte, tema escuro/sépia e restauração da seção/rolagem.
- Exclusão com confirmação. Falhas de armazenamento não apagam a biblioteca.
- Layout adaptável a celular e desktop. Fontes incluídas no pacote.

## Abertura do Livro

O livro selecionado na mesa começa a ser preparado após 120 ms sem troca de
seleção. A abertura reaproveita o documento preparado e o trabalho já iniciado.
Downloads também preservam o resultado validado para a primeira leitura. O cache
é somente em memória, com até três documentos e 64 MiB estimados; recarregar o
aplicativo exige preparar o EPUB novamente.

O leitor calcula primeiro a página da posição salva, sem esperar a paginação do
livro inteiro. Os demais cálculos avançam entre frames, com lotes de até oito
páginas e orçamento alvo de 4 ms. Totais permanecem como “Calculando páginas…”
até estarem completos. Resize, acessibilidade e mudança de fonte descartam o
layout anterior sem alterar o ponto salvo.

A transição mantém a posição e a rotação do livro 3D, abre a capa e revela o texto
real em 900 ms quando a página está pronta até 630 ms. Preparação mais lenta
mantém uma espera explícita e permite cancelar; nunca revela uma página vazia.
Movimento reduzido remove a animação. Erros exibem a tentativa novamente do leitor.

Na web, o parser cede a execução entre lotes de arquivos e capítulos. Não há Web
Worker: a descompactação de uma entrada e a análise de um HTML individual ainda
são operações atômicas. A animação de 900 ms não garante abertura abaixo de um
segundo para todo EPUB ou dispositivo. O evento de timeline `Book opening` mede
do clique até o frame final de leitura, com `elapsedMs`, ou registra cancelamento.
Os testes de transição validam o relógio simulado; não substituem medições reais
em build release, com cache frio e quente.

Formato inicial: **EPUB sem DRM**, até 40 MiB. Não há leitor PDF,
sincronização entre dispositivos nem agrupamento por arrastar nesta versão.
O leitor preserva texto, títulos e imagens locais; não reproduz CSS editorial,
tabelas complexas, estilos inline ou links de notas. Não inventa páginas:
EPUB refluível usa seções, em vez dos números fixos exibidos no mockup.

## Catálogo e Z-Library

**Conector implementado para a versão web local**, usando a interface JSON
não oficial `/eapi` em `https://z-library.biz`. A busca pela ponte local foi
validada com o serviço real: 20 EPUBs de `Dom Casmurro` e paginação. Após a
correção de destinos, um EPUB de Dom Casmurro foi baixado pela conta conectada,
importado para a biblioteca e aberto no leitor. A restauração automática da
sessão é coberta por testes simulados; não faz login remoto em segundo plano.

Para usar, execute o build com `node tool/serve.mjs` e abra o endereço loopback
mostrado pelo servidor. Em **Descobrir > Fontes e contas**, selecione Z-Library.
Busque por título ou autor; para baixar, conecte sua conta nessa tela. Categorias
Gutendex não são enviadas ao Z-Library. Sem sessão restaurável, o provedor inicial
continua Gutenberg. Uma sessão restaurada seleciona Z-Library automaticamente.
Trocar de fonte ou sair da conta não
remove livros já importados.

O formulário de conta envia email/senha somente pela ponte dedicada
`/api/zlibrary/login`, que chama o domínio fixo por HTTPS. A senha é limpa do
campo antes da requisição e não é persistida. O servidor retém os identificadores
remotos de sessão cifrados em `.local/zlibrary/`; o Flutter recebe um token local opaco.
Um cookie local `HttpOnly`, `SameSite=Strict`, limitado a `/api/zlibrary/`, permite
restaurá-lo após recarregar pelo POST `/api/zlibrary/session`. Esse endpoint exige
os mesmos controles de origem, JSON e cabeçalho específico. A senha nunca é
salva em arquivo, Hive, cookie ou build. Cada autorização de acesso dura 30 minutos.
A conta é lembrada por 30 dias renováveis: abrir o app ou entrar em Descobrir
renova o acesso e o prazo do cookie, sem enviar senha nem fazer novo login remoto.
Chamadas simultâneas compartilham a mesma renovação; uma falha de conexão preserva
o acesso ainda válido, enquanto 401 o revoga. Um download com autorização expirada
tenta restaurá-la antes de solicitar o arquivo. A restauração não bloqueia a
biblioteca offline nem substitui uma seleção manual de fonte. Reiniciar normalmente
o servidor preserva a sessão. Uma revogação no serviço exige login explícito.
Como o servidor é HTTP loopback, o cookie não usa `Secure`;
não exponha esse servidor publicamente. Sair revoga a sessão local e bloqueia sua
restauração, mas não encerra outras sessões da conta no serviço. O cookie revogado
expira pelo prazo original, sem que respostas antigas de logout apaguem um novo
login. O Hive guarda somente a intenção booleana de permitir restauração, nunca
senha ou token. Sair bloqueia essa intenção antes de concluir, inclusive com a
ponte offline; um novo login explícito a reabilita. Se não for possível persistir
a saída, o aplicativo informa o erro e exige repetir antes de fechar.

O armazenamento usa AES-256-GCM com chave local separada, diretório `700` e
arquivos `600`, fora do build e ignorados pelo Git. Não protege contra quem já
controla a conta do sistema e pode ler a chave. Um lock exclusivo impede dois
servidores de sobrescrever revogações. Ctrl+C encerra requisições e libera o lock;
uma interrupção abrupta pode deixá-lo abandonado. Nesse caso o servidor falha
fechado: antes de remover apenas o diretório vazio `.local/zlibrary/writer.lock`,
confirme que nenhum processo usa esse armazenamento. Nunca apague a chave ou o
arquivo de sessões para corrigir um lock. Não há migração de sessões antigas
mantidas apenas em memória: é necessário conectar uma vez nesta versão.

O servidor aceita somente requisições locais com Host/Origin válidos. Operações
POST exigem JSON e cabeçalho específico. Não há CORS aberto. Login tem limite de
cinco tentativas por minuto, e o servidor admite até 32 sessões simultâneas. Respostas de conta
e livros não são armazenadas em cache; erros não refletem dados remotos. HTML,
verificações de navegador e redirecionamentos da API falham sem contorno ou
repetição automática.

Downloads usam a sessão para obter o link; o cliente não recebe links assinados.
O arquivo deve ser EPUB, ter assinatura ZIP e até 40 MiB; a importação ainda
valida o conteúdo com o leitor existente. A ponte só aceita HTTPS na porta 443,
no domínio `z-library.biz`, em `cdn-zlib.sk`/subdomínios ou no host exato
`dln1.ncdn.ec`, conferindo cada redirecionamento. Links iniciais relativos à raiz
são resolvidos em `https://z-library.biz`, nunca no endereço do aplicativo.
Cookies remotos nunca são enviados ao CDN. Destinos diferentes
falham de forma fechada e exigem análise antes de ampliar a lista. Esses controles
não comprovam os direitos de uma obra: use somente material autorizado e respeite
as cotas do serviço. A busca inclui capas públicas pelo endpoint dedicado
`GET /api/zlibrary/cover?url=...`, sem exigir login ou encaminhar cookies/tokens.
Somente o host verificado `s3proxy-alp2-covers.cdn-zlib.sk`, caminhos de capas
JPEG/PNG/WebP e HTTPS na porta 443 são aceitos, inclusive em redirecionamentos
(até três). Respostas têm limite de 2 MiB e validação de MIME e assinatura.
Ausência, destino não aprovado ou falha da imagem mantém a capa ilustrativa,
sem bloquear os resultados. Após importar, a capa do EPUB tem prioridade.

O endereço HTTPS salvo continua em uma caixa Hive separada e não contém segredos.
Salvar não autentica, não inicia requisições nem altera o destino fixo do conector.
Um endereço diferente do domínio aprovado bloqueia seleção/login até ser corrigido
ou removido. Uma falha nesse armazenamento não bloqueia a biblioteca. Senhas e
tokens não devem ser enviados pelo chat, salvos no Hive, incluídos no build ou
encaminhados pelo proxy público `/api/proxy`, cuja allowlist não foi ampliada.

O conector fica indisponível em builds nativos ou hospedagem pública nesta etapa;
isso não bloqueia biblioteca, importação ou Gutenberg. A versão web requer o
servidor Node próprio: `flutter run -d chrome` sozinho não oferece a ponte.
O contrato interno `BookCatalog` e `CatalogSources` mantém os provedores separados
sem alterar o formato da biblioteca ou o leitor offline.

### Validação do Site em 30/10/2026

O endereço informado, `https://z-library.biz/`, foi encontrado na cadeia pública
de links do serviço: `https://z-lib.sk/` aponta para
`https://library-access.sk/`, cujo link **Open Official Website** aponta para
`https://z-library.biz/?from=z-access`. Isso confirma o destino anunciado nessa
data, não um contrato de API, autorização de automação ou segurança dos arquivos.

No navegador, a busca pública por `Dom Casmurro` abriu
`https://z-library.biz/s/Dom%20Casmurro`. O detalhe
`https://z-library.biz/book/ZKRnBqX4Kj/dom-casmurro.html` anunciou EPUB de 564 KB.
Nenhum download foi realizado ou validado. Acesso público pelo navegador não
comprova acesso pelo cliente Flutter nem pelo proxy Node.

Requisições HTTP diretas à página inicial receberam 503 com
**Checking your browser ...**. A página `/login` apresentou
**Web server is down**, erro 521; uma nova consulta HTTP reproduziu 521 com
verificação TLS válida. São bloqueios distintos: verificação de navegador no
acesso direto e indisponibilidade do login na consulta realizada.

Na investigação inicial, não foi encontrado um contrato verificável de
autenticação/API. O primeiro código de terceiros consultado descreve automação
de navegador, não uma API documentada. A investigação adicional abaixo encontrou
uma interface JSON com busca e detalhes funcionais.
Nenhuma credencial, cookie ou token foi coletado. Não foi implementado adapter
baseado em endpoints presumidos nem contorno da verificação de navegador.

A investigação pública não validou autenticação nem download de um EPUB autorizado.
O conector descrito acima usa a alternativa JSON, sem modificar o proxy público.

### Correção do Download em 30/10/2026

Após o usuário confirmar o login, a interface mostrou
`O destino do arquivo ainda não foi aprovado pelo conector.` (`HOST_NOT_ALLOWED`).
A ponte agora aceita links relativos à raiz e o host exato `dln1.ncdn.ec`, sem
liberar todo `*.ncdn.ec` nem alterar o proxy público. O suporte a links relativos
também aparece no [cliente comunitário](https://github.com/rookslog/zlibrary-mcp/blob/496a9290369e28c797af49caad832f7d542739f6/zlibrary/src/zlibrary/eapi.py#L503-L519).
O host foi identificado como CDN de livros em
[relato público de setembro de 2026](https://github.com/psylch/skill-issues/issues/16),
corroborado por um [registro independente](https://github.com/zerx-lab/FluxDown/issues/411).
Uma consulta HEAD à raiz do CDN confirmou HTTPS com TLS válido; isso não comprova
o download de um livro nem que esse foi o destino rejeitado na sessão do usuário.

Testes de regressão cobrem link relativo, redirect até o novo CDN, acesso direto,
ausência de cookies no CDN e bloqueio de hosts semelhantes, portas e protocolos
não aprovados. Naquela etapa a sessão permanecia somente em memória; a versão
atual usa a persistência cifrada descrita acima. Não há contorno de cotas,
permissões ou verificações do provedor.

Com a conta conectada pelo usuário, o primeiro resultado de Dom Casmurro foi
baixado, apareceu na Biblioteca e abriu no leitor. A validação usou apenas
texto/semântica do Chrome, sem capturas. Nenhuma senha foi adicionada ao código.

### Abertura Mais Rápida

O parser reutiliza os bytes descompactados que já passaram por tamanho e CRC,
em vez de descompactar e verificar cada entrada duas vezes. Entradas não usadas
também continuam sendo verificadas. O benchmark sintético local, com 8 MiB
binários adicionais, caiu de mediana de 564 ms para 352 ms (cerca de 38%, cinco
amostras após aquecimento). Esse número mede o parser na VM de teste, não o tempo
total de abertura no navegador. Paginação e carregamento inicial continuam com
custos próprios. Testes cobrem integridade, entradas não comprimidas e leitura.

### Alternativa JSON Verificada em 30/10/2026

O cliente comunitário [Zlibrary-API](https://github.com/bipinkrish/Zlibrary-API/blob/6f9f14a1b6bdd92e276207486b1e0b0277d58fa6/Zlibrary.py)
descreve chamadas à interface `/eapi`. O código tem licença MIT, mas não constitui
documentação oficial do serviço. Seu último commit consultado é de 18/10/2024;
a data recente de atualização do repositório não comprova manutenção do código.

Consultas diretas, sem conta, cookies ou tokens, confirmaram em `z-library.biz`:

- `GET /eapi/user/profile`: JSON com `success: 0` e `Please login` (HTTP 400).
- `POST /eapi/book/search`: HTTP 200, `success: 1`, com `message=Dom Casmurro`,
  `extensions[]=epub`, `page=1` e `limit=1`. Retornou livro de Machado de Assis,
  ID `4780945`, hash `94cb23`, EPUB anunciado de 564 KB.
- `GET /eapi/book/4780945/94cb23`: HTTP 200, `success: 1` e metadados do livro.
- `GET /eapi/book/4780945/94cb23/file`: JSON com `success: 0` e `Please login`
  (HTTP 400). Nenhum link de arquivo foi fornecido; nenhum EPUB foi baixado.

Isso verifica uma alternativa à extração de HTML para busca e detalhes, não o
download completo. O cliente comunitário descreve `POST /eapi/user/login`, mas
essa chamada não foi executada nem validada. A falha 521 no login HTML não
comprova falha nesse endpoint JSON. Não houve tentativa de contornar autenticação
ou verificação de navegador.

O adapter e a ponte foram implementados com esse contrato observado de busca e
com o contrato comunitário de login/arquivo. Uma consulta real pela ponte retornou
HTTP 200 e 20 registros normalizados, com `hasNext: true`. Ainda é necessário
validar autenticação e download com uma conta, sem contornar desafios ou limites.

Como alternativas de uso externo, `https://library-access.sk/` anuncia apps
desktop/Android e bot pessoal do Telegram. O bot exige autorização prévia no
site. Esses canais não foram instalados, autenticados nem testados para download;
não equivalem a integração com o aplicativo. Um EPUB sem DRM obtido legitimamente
por esses canais pode ser aberto pela importação já existente do Leitura Anywhere.

O catálogo inicial é o **Projeto Gutenberg via Gutendex**, filtrado por português,
EPUB e `copyright=false`. O estado de domínio público do Gutenberg refere-se
aos Estados Unidos; confira os direitos aplicáveis no seu país.

`BOOK_CATALOG_URL` aceita um endpoint **HTTPS sem credenciais na URL** com
contrato Gutendex: parâmetros `search`, `topic`, `page`, `languages`, `mime_type`,
`copyright`; resposta `{results: [...], next: string|null}`; livros com `id` inteiro,
`title`, `authors: [{name}]`, `subjects` e `formats` contendo `application/epub+zip`
e, opcionalmente, `image/jpeg`. O adapter usa IDs `gutenberg:<id>` e não é
um cliente genérico de Z-Library. O conector separado usa IDs
`zlibrary:<id>:<hash>` e não envia credenciais ao adapter Gutendex.

```sh
flutter run --dart-define=BOOK_CATALOG_URL=https://catalogo.example/books/ \
  --dart-define=BOOK_CATALOG_NAME="Meu catálogo"
```

Na web, o proxy permite **somente** `gutendex.com`, `gutenberg.org` e
`www.gutenberg.org`, em HTTPS/443. Catálogo personalizado na web exige revisão
explícita dessa allowlist e do contrato, não um proxy aberto. Nunca inclua chaves
privadas em `--dart-define`: elas ficam no aplicativo.

## Executar no Navegador

Requisitos: Flutter estável com Dart >=3.9 e Node >=22. Ambiente usado:
Flutter 3.47.9 / Dart 3.13.7. Nesta máquina o SDK de sessão fica em
`/tmp/opencode-sanar/flutter-sdk`; se não houver `flutter` no PATH, use
`/tmp/opencode-sanar/flutter-sdk/bin/flutter` nos comandos abaixo.

```sh
flutter pub get
flutter build web
node tool/serve.mjs --port 8787
```

Endereço: `http://localhost:8787`. O servidor escuta apenas em `127.0.0.1`,
não publica o aplicativo na internet. Encerre com Ctrl+C.

O servidor serve `build/web` e faz a ponte CORS de catálogo, capas e downloads.
O proxy público valida cada redirect, não encaminha cookies/tokens e limita
bytes e tempo. O conector Z-Library usa as rotas dedicadas descritas acima;
somente ele mantém a autorização remota, cifrada no armazenamento local.
O cliente aguarda até 50 segundos por requisição; o proxy limita a operação a
45 segundos. O catálogo externo pode ficar temporariamente indisponível; a
interface permite tentar novamente sem apagar livros já salvos.
**`flutter run -d chrome` sozinho não fornece esse proxy**: a interface e os
EPUBs importados funcionam, mas catálogo/download precisam da rota `/api/proxy`
no mesmo origin, implementada por `tool/serve.mjs`.

Os livros web ficam no IndexedDB. Limpar dados do site ou usar modo privado pode
removê-los; não são criptografados nem sincronizados. Livros baixados podem ser
lidos sem rede enquanto o app estiver aberto. Reabrir o app web offline não é
garantido: não há cache offline do shell. No mobile, app e livros salvos funcionam
offline após instalados.

## Android e iOS

```sh
flutter doctor
flutter devices
flutter run -d <id-do-dispositivo>
flutter build apk --release
# No macOS:
flutter build ios --no-codesign
```

Android exige JDK, Android SDK e dispositivo/emulador. A permissão de rede está
no manifest de release; importação usa o seletor do sistema, sem permissão ampla
de armazenamento. iOS exige macOS, Xcode e assinatura.

Projetos Android/iOS gerados, mas build nativo e testes em dispositivo ainda não
validados neste ambiente. Ícones são os padrões do Flutter. A fidelidade visual
final ao `.pen` depende de revisão visual autorizada.

## Verificação

```sh
flutter analyze
flutter test
node --test tool/serve.test.mjs tool/zlibrary.test.mjs
# Opcional, rede real, fora da suíte determinística:
flutter test test/catalog_live_test.dart --dart-define=LIVE_BOOK_TEST=true
```

Testes cobrem parsing, ordem spine, HTML não confiável, limites de ZIP,
persistência/retomada, catálogo, redirects, timeout, limites de download,
layout/navegação em diferentes larguras e fluxo download/biblioteca/leitor.
Os testes Node cobrem proxy restrito, limites, arquivos estáticos e a ponte
Z-Library: autenticação simulada, expiração/revogação, validação de origem,
paginação e isolamento de credenciais durante redirects e downloads.
Testes de interface usam Hive em memória para não misturar I/O de disco com o
relógio simulado do Flutter. Testes de dados verificam fechamento, reabertura e
persistência em disco real. A navegação também é testada com texto a 200% em
320 × 568, 430 × 952 e 1280 × 800 pixels.

Validação local em 28/10/2026: análise sem problemas, 51 testes Flutter e
46 testes Node aprovados; teste opcional de busca/download/parsing real também
aprovado. Build web gerado. No Chrome, `Historias Sem Data`, de Machado de Assis,
foi baixado, aberto sem rede com o app já carregado e retomado na seção 2 após
recarregar o aplicativo. A rede foi restaurada depois do teste. O build emite
um aviso de fonte Cupertino ausente; revisão visual e builds nativos continuam
pendentes.

Validação da preparação de integração em 30/10/2026: análise sem problemas,
150 testes Flutter e 46 testes Node aprovados; 1 teste de rede real ignorado
por ser opt-in. Os 24 novos testes cobrem configuração, persistência, validação
de endereço, recuperação de falha de armazenamento, layout com texto a 200% e
uso de outro adapter até o download para a biblioteca. Build web atualizado
com Flutter 3.47.9 / Dart 3.13.7. O aviso de fonte Cupertino permanece.
Autenticação Z-Library e revisão visual não foram validadas nesta etapa.

Validação do conector em 30/10/2026: análise sem problemas, 196 testes Flutter
e 81 testes Node aprovados; 1 teste de rede real ignorado por ser opt-in.
Build web atualizado com sucesso. No Chrome, a seleção da fonte e a busca por
`Dom Casmurro` exibiram 20 resultados reais sem conectar uma conta. A conferência
usou a árvore de acessibilidade, sem capturas; não comprova a aparência final.
Login e download Z-Library foram validados somente com respostas simuladas.
Nenhuma credencial real foi usada e nenhum EPUB do serviço foi baixado.
O aviso de fonte Cupertino, a revisão visual e os builds nativos seguem pendentes.

Validação das capas em 30/10/2026: 200 testes Flutter e 87 testes Node aprovados;
1 teste de rede real ignorado por ser opt-in. Análise sem problemas e build web
gerado. No Chrome, uma busca pública por `Dom Casmurro` carregou 19 capas com
resposta 200 entre 20 resultados; a obra sem capa manteve a ilustração. Uma capa
foi decodificada como imagem de 289 × 445 pixels. Conferência textual e de rede,
sem capturas; a revisão visual permanece pendente. O aviso Cupertino permanece.

Validação de download, desempenho e sessão em 30/10/2026: 229 testes Flutter e
93 testes Node aprovados; 1 teste de rede real ignorado por ser opt-in. Análise
sem problemas e build web concluído. O download real de Dom Casmurro foi
confirmado antes da atualização. Após reiniciar a ponte e recarregar o build
final, a biblioteca permaneceu salva e o livro reabriu na página 1 de 744.
A restauração de conta, o bloqueio após logout offline e as corridas de sessão
foram validados com respostas simuladas; falta novo login para conferir a
restauração no navegador com conta real. Não foram capturadas imagens. O aviso
Cupertino, a revisão visual e os builds nativos continuam pendentes.

Validação da renovação em 30/10/2026: 282 testes Flutter e 114 testes Node
aprovados; 1 teste de rede real ignorado por ser opt-in. Análise sem problemas
e build web gerado. Os testes cobrem persistência cifrada, escritor exclusivo,
reinício normal, logout após expiração, concorrência, falhas de armazenamento,
offline e respostas tardias após logout ou 401. No Chrome, desktop 1536 × 791
e mobile 390 × 844 abriram o catálogo e a tela de conta, sem overflow horizontal
do documento. Foram observadas duas chamadas de restauração por carregamento:
uma no bootstrap e outra ao entrar em Descobrir. Os livros permaneceram salvos
após reiniciar a ponte. Conferência textual, sem capturas; não comprova aparência
final. A renovação autenticada foi validada apenas com respostas simuladas:
conecte uma vez para criar a primeira sessão persistente nesta versão. O aviso
de fonte Cupertino permanece; não impediu o build.

## Estrutura e Segurança

- `lib/main.dart`: inicialização e recuperação de falhas.
- `lib/app.dart`: tema, navegação, mesa, biblioteca e importação.
- `lib/data/`: modelos, catálogo e persistência Hive.
- `lib/ui/`: catálogo e capas.
- `lib/reader/`: validação de EPUB e leitor.
- `tool/serve.mjs`: servidor local e proxy web restrito.
- `tool/zlibrary_session_store.mjs`: persistência cifrada e exclusão de escritor.

EPUBs são dados não confiáveis. Antes do parser há verificação de diretório ZIP,
tamanho expandido (120 MiB), entradas (3000), integridade, paths e inflação
limitada. ZIP64, arquivos divididos/criptografados e symlinks não são suportados.
Scripts, iframes e recursos externos do EPUB não são executados/carregados.
HTML é convertido em widgets Flutter, sem WebView.

Conteúdo binário é salvo uma vez por livro. Posição/mesa usam checkpoints pequenos,
sem reescrever o EPUB a cada rolagem. Posição é salva com debounce e antes de
voltar; erro de persistência permanece visível para nova tentativa.
