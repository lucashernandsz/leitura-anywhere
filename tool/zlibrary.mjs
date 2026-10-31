import { randomBytes } from 'node:crypto';

const API = 'https://z-library.biz';
const LOCAL_LIMIT = 16 * 1024;
const JSON_LIMIT = 4 * 1024 * 1024;
const FILE_LIMIT = 40 * 1024 * 1024;
const COVER_LIMIT = 2 * 1024 * 1024;
const SESSION_MS = 30 * 60 * 1000;
const REMEMBERED_MS = 30 * 24 * 60 * 60 * 1000;
const SESSION_COOKIE = 'leitura_zlibrary_session';
const COOKIE_OPTIONS = 'Path=/api/zlibrary/; HttpOnly; SameSite=Strict';
const REDIRECTS = new Set([301, 302, 303, 307, 308]);
const STORE_OWNERS = new WeakSet();
const MESSAGES = {
  INVALID_REQUEST: 'Requisicao invalida.',
  AUTH_REQUIRED: 'Entre novamente para continuar.',
  UPSTREAM_UNAVAILABLE: 'Servico de livros indisponivel. Tente mais tarde.',
  INVALID_RESPONSE: 'O servico de livros retornou uma resposta invalida.',
  DOWNLOAD_DENIED: 'Download deste livro nao permitido.',
  HOST_NOT_ALLOWED: 'Destino de download nao permitido.',
  TOO_LARGE: 'O conteudo excede o limite permitido.',
  TIMEOUT: 'O servico de livros demorou demais para responder.',
  RATE_LIMITED: 'Muitas tentativas. Aguarde antes de tentar novamente.',
  SESSION_LIMIT: 'Limite de sessoes atingido. Encerre uma sessao e tente novamente.',
  FORBIDDEN: 'Requisicao local nao permitida.',
  NOT_FOUND: 'Operacao nao encontrada.',
  METHOD_NOT_ALLOWED: 'Metodo nao permitido.',
};

class ApiError extends Error {
  constructor(status, code) {
    super(MESSAGES[code]);
    this.status = status;
    this.code = code;
  }
}

function fail(status, code) { throw new ApiError(status, code); }
function record(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function positive(value) { return Number.isSafeInteger(value) && value > 0; }
function hash(value) { return typeof value === 'string' && /^[a-zA-Z0-9]{1,64}$/.test(value); }
function text(value, max, empty = false) {
  return typeof value === 'string' && value.length <= max && (empty || value.trim().length > 0)
    && !/[\x00-\x1f\x7f]/.test(value);
}
function cancel(body) {
  try { return Promise.resolve(body?.cancel()).catch(() => {}); }
  catch { return Promise.resolve(); }
}

function send(response, status, body, type = 'application/json; charset=utf-8') {
  if (response.destroyed || response.writableEnded) return;
  const bytes = Buffer.isBuffer(body) ? body : Buffer.from(JSON.stringify(body));
  response.writeHead(status, {
    'Content-Type': type,
    'Content-Length': bytes.length,
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'Cross-Origin-Resource-Policy': 'same-origin',
  });
  response.end(bytes);
}

function guard(request, cover = false) {
  for (const name of ['host', 'origin', 'sec-fetch-site', 'content-type', 'x-leitura-client', 'authorization', 'cookie']) {
    let count = 0;
    for (let index = 0; index < request.rawHeaders.length; index += 2) {
      if (request.rawHeaders[index].toLowerCase() === name) count++;
    }
    if (count > 1) fail(400, 'INVALID_REQUEST');
  }
  const host = request.headers.host ?? '';
  const match = /^(localhost|127\.0\.0\.1|\[::1\])(?::([0-9]{1,5}))?$/.exec(host);
  if (!match || Number(match[2] ?? 80) !== request.socket.localPort) fail(403, 'FORBIDDEN');
  if (request.headers.origin !== undefined && request.headers.origin !== `http://${host}`) fail(403, 'FORBIDDEN');
  if (request.headers['sec-fetch-site']?.toLowerCase() === 'cross-site') fail(403, 'FORBIDDEN');
  if (cover) return;
  if (request.headers['x-leitura-client'] !== '1'
    || !/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(request.headers['content-type'] ?? '')
    || request.headers['content-encoding'] !== undefined) fail(400, 'INVALID_REQUEST');
}

function localBody(request, signal) {
  const declared = request.headers['content-length'];
  if (declared !== undefined && (!/^\d+$/.test(declared) || BigInt(declared) > BigInt(LOCAL_LIMIT))) {
    fail(413, 'TOO_LARGE');
  }
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    const finish = (error, value) => {
      request.off('data', data);
      request.off('end', end);
      request.off('error', errorEvent);
      signal.removeEventListener('abort', aborted);
      if (error) reject(error);
      else resolve(value);
    };
    const data = (chunk) => {
      size += chunk.length;
      if (size > LOCAL_LIMIT) finish(new ApiError(413, 'TOO_LARGE'));
      else chunks.push(chunk);
    };
    const end = () => {
      try { finish(null, JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
      catch { finish(new ApiError(400, 'INVALID_REQUEST')); }
    };
    const errorEvent = () => finish(new ApiError(400, 'INVALID_REQUEST'));
    const aborted = () => finish(signal.reason);
    request.on('data', data);
    request.once('end', end);
    request.once('error', errorEvent);
    signal.addEventListener('abort', aborted, { once: true });
    if (signal.aborted) aborted();
  });
}

function schema(operation, value) {
  const keys = {
    search: ['query', 'page'], login: ['email', 'password'], logout: [], session: [], download: ['id', 'hash'],
  }[operation];
  if (!record(value) || Object.keys(value).length !== keys.length
    || !keys.every((key) => Object.hasOwn(value, key))) fail(400, 'INVALID_REQUEST');
  if (operation === 'search' && (!text(value.query, 1000, true) || !positive(value.page))) fail(400, 'INVALID_REQUEST');
  if (operation === 'login' && (!text(value.email, 320) || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value.email)
    || !text(value.password, 1024))) fail(400, 'INVALID_REQUEST');
  if (operation === 'download' && (!positive(value.id) || !hash(value.hash))) fail(400, 'INVALID_REQUEST');
}

function fileUrl(value, base) {
  if (typeof value !== 'string' || !value.length || value.length > 8192 || /[\\\x00-\x20\x7f]/.test(value)) fail(502, 'HOST_NOT_ALLOWED');
  // The API can return a root-relative download link, not just a CDN URL.
  if (!base && value.startsWith('/') && !value.startsWith('//')) base = API;
  if (!base && !/^https:\/\//i.test(value)) fail(502, 'HOST_NOT_ALLOWED');
  // Validate the raw Location too: URL parsing would otherwise erase backslashes and controls.
  let url;
  try { url = base ? new URL(value, base) : new URL(value); }
  catch { fail(502, 'HOST_NOT_ALLOWED'); }
  const authority = /^(?:[a-z][a-z0-9+.-]*:)?\/+([^/?#]*)/i.exec(value)?.[1];
  if (url.protocol !== 'https:' || url.username || url.password || authority?.includes('@')
    || (url.port && url.port !== '443') || url.hash
    || !(url.hostname === 'z-library.biz' || url.hostname === 'dln1.ncdn.ec' || url.hostname === 'cdn-zlib.sk'
      || /^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+cdn-zlib\.sk$/.test(url.hostname))) {
    fail(502, 'HOST_NOT_ALLOWED');
  }
  return url;
}

function coverUrl(value, base) {
  const url = fileUrl(value, base);
  if (url.hostname !== 's3proxy-alp2-covers.cdn-zlib.sk' || url.search
    || !/^\/covers\d*\/[a-zA-Z0-9/_-]+\.(?:jpe?g|png|webp)$/.test(url.pathname)) {
    fail(502, 'HOST_NOT_ALLOWED');
  }
  return url;
}

async function bounded(upstream, limit, signal, cancelBody) {
  const length = upstream.headers.get('content-length');
  if (length !== null && /^\d+$/.test(length) && BigInt(length) > BigInt(limit)) {
    cancelBody(upstream.body);
    fail(413, 'TOO_LARGE');
  }
  if (!upstream.body) fail(502, 'INVALID_RESPONSE');
  const reader = upstream.body.getReader();
  const abort = () => cancelBody(reader);
  signal.addEventListener('abort', abort, { once: true });
  const chunks = [];
  let size = 0;
  try {
    for (;;) {
      signal.throwIfAborted();
      const { done, value } = await reader.read();
      signal.throwIfAborted();
      if (done) break;
      size += value.byteLength;
      if (size > limit) fail(413, 'TOO_LARGE');
      chunks.push(Buffer.from(value));
    }
    return Buffer.concat(chunks, size);
  } finally {
    signal.removeEventListener('abort', abort);
    cancelBody(reader);
  }
}

function pleaseLogin(value) {
  return [value?.message, value?.error, value?.error?.message].some(
    (message) => typeof message === 'string' && /please\s+log\s*in/i.test(message),
  );
}

export function createZlibraryHandler({ fetchImpl = globalThis.fetch, timeoutMs = 45_000, now = Date.now, sessionStore } = {}) {
  if (typeof fetchImpl !== 'function' || typeof now !== 'function'
    || !Number.isSafeInteger(timeoutMs) || timeoutMs <= 0
    || (sessionStore !== undefined && (typeof sessionStore?.load !== 'function'
      || typeof sessionStore?.save !== 'function'
      || (sessionStore.close !== undefined && typeof sessionStore.close !== 'function')))) {
    throw new Error('Invalid Z-Library handler options.');
  }
  let sessions;
  try {
    if (sessionStore && STORE_OWNERS.has(sessionStore)) throw new Error('Store already owned.');
    sessions = new Map((sessionStore?.load() ?? []).map(({ token, ...session }) => [token, session]));
  } catch { throw new Error('Z-Library session storage unavailable.'); }
  if (sessionStore) STORE_OWNERS.add(sessionStore);
  const active = new Map();
  let attempts = [];
  let pendingLogins = 0;
  let closed = false;
  let closing;
  let storageFailed = false;
  let loginGeneration = 0;
  const persist = (next) => {
    if (storageFailed) fail(502, 'UPSTREAM_UNAVAILABLE');
    try { sessionStore?.save([...next].map(([token, session]) => ({ token, ...session }))); }
    catch {
      // Disk outcome may be uncertain. Block this handler until storage is repaired/reloaded.
      storageFailed = true;
      fail(502, 'UPSTREAM_UNAVAILABLE');
    }
  };
  const revoke = (token) => {
    if (!sessions.has(token)) return;
    const next = new Map(sessions);
    next.delete(token);
    persist(next);
    sessions = next;
  };
  const cleanup = () => {
    const next = new Map([...sessions].filter(([, session]) => session.rememberedUntil > now()));
    if (next.size !== sessions.size) {
      persist(next);
      sessions = next;
    }
    attempts = attempts.filter((time) => time > now() - 60_000);
  };

  const handler = async (request, response) => {
    if (closed) {
      send(response, 502, { error: MESSAGES.UPSTREAM_UNAVAILABLE, code: 'UPSTREAM_UNAVAILABLE' });
      request.resume();
      return;
    }
    const controller = new AbortController();
    const { signal } = controller;
    let finished;
    active.set(controller, new Promise((resolve) => { finished = resolve; }));
    const cancellations = [];
    const cancelBody = (body) => { cancellations.push(cancel(body)); };
    const disconnected = () => {
      if (!response.writableFinished) controller.abort(new ApiError(400, 'INVALID_REQUEST'));
    };
    response.once('close', disconnected);
    request.once('aborted', disconnected);
    let timer;
    const stopped = new Promise((_, reject) => {
      signal.addEventListener('abort', () => reject(signal.reason), { once: true });
      timer = setTimeout(() => controller.abort(new ApiError(504, 'TIMEOUT')), timeoutMs);
    });
    const fetchRemote = async (url, options = {}) => {
      signal.throwIfAborted();
      const upstream = await fetchImpl(url, {
        ...options, redirect: 'manual', credentials: 'omit', signal,
      });
      if (signal.aborted) {
        cancelBody(upstream.body);
        signal.throwIfAborted();
      }
      return upstream;
    };
    let token;
    let session;
    let cookieToken;
    let renewing = false;
    const initialLoginGeneration = loginGeneration;
    let binaryType = 'application/epub+zip';
    let reservedLogin = false;
    const releaseLogin = () => {
      if (reservedLogin) pendingLogins--;
      reservedLogin = false;
    };
    const requireSession = (remembered = false) => {
      cleanup();
      if (storageFailed || closed) fail(502, 'UPSTREAM_UNAVAILABLE');
      if (!session || sessions.get(token) !== session
        || (!remembered && session.expires <= now())) fail(401, 'AUTH_REQUIRED');
    };
    const readJson = async (upstream, authenticatedHost = false) => {
      if (!/^application\/json(?:\s*;|$)/i.test(upstream.headers.get('content-type') ?? '')) {
        cancelBody(upstream.body);
        fail(502, 'INVALID_RESPONSE');
      }
      const bytes = await bounded(upstream, JSON_LIMIT, signal, cancelBody);
      let value;
      try { value = JSON.parse(bytes.toString('utf8')); } catch { fail(502, 'INVALID_RESPONSE'); }
      if (!record(value)) fail(502, 'INVALID_RESPONSE');
      if (pleaseLogin(value)) {
        if (!authenticatedHost) fail(502, 'INVALID_RESPONSE');
        if (token) revoke(token);
        fail(401, 'AUTH_REQUIRED');
      }
      return value;
    };
    const remoteJson = async (path, options) => {
      const upstream = await fetchRemote(`${API}${path}`, options);
      if (upstream.status === 401) {
        cancelBody(upstream.body);
        if (token) revoke(token);
        fail(401, 'AUTH_REQUIRED');
      }
      const jsonType = /^application\/json(?:\s*;|$)/i.test(upstream.headers.get('content-type') ?? '');
      const value = jsonType ? await readJson(upstream, true) : undefined;
      if (!upstream.ok) {
        cancelBody(upstream.body);
        fail(502, 'UPSTREAM_UNAVAILABLE');
      }
      if (!jsonType) {
        cancelBody(upstream.body);
        fail(502, 'INVALID_RESPONSE');
      }
      return value;
    };
    const run = async () => {
      if (closed || storageFailed) fail(502, 'UPSTREAM_UNAVAILABLE');
      const cover = /^\/api\/zlibrary\/cover\?([^#]*)$/.exec(request.url ?? '');
      guard(request, cover !== null);
      if (cover) {
        if (request.method !== 'GET') {
          response.setHeader('Allow', 'GET');
          fail(405, 'METHOD_NOT_ALLOWED');
        }
        const query = new URLSearchParams(cover[1]);
        if ([...query.keys()].length !== 1 || !query.has('url')) fail(400, 'INVALID_REQUEST');
        let url = coverUrl(query.get('url'));
        for (let redirects = 0; ; redirects++) {
          const upstream = await fetchRemote(url.href, {
            method: 'GET', headers: { Accept: 'image/jpeg, image/png, image/webp' },
          });
          if (REDIRECTS.has(upstream.status)) {
            cancelBody(upstream.body);
            if (redirects >= 3) fail(502, 'INVALID_RESPONSE');
            url = coverUrl(upstream.headers.get('location'), url);
            continue;
          }
          if (!upstream.ok) {
            cancelBody(upstream.body);
            fail(502, 'UPSTREAM_UNAVAILABLE');
          }
          const type = (upstream.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase();
          if (!['image/jpeg', 'image/png', 'image/webp'].includes(type)) {
            cancelBody(upstream.body);
            fail(502, 'INVALID_RESPONSE');
          }
          const bytes = await bounded(upstream, COVER_LIMIT, signal, cancelBody);
          const valid = type === 'image/jpeg' ? bytes.subarray(0, 3).equals(Buffer.from([0xff, 0xd8, 0xff]))
            : type === 'image/png' ? bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))
              : bytes.length >= 12 && bytes.toString('ascii', 0, 4) === 'RIFF' && bytes.toString('ascii', 8, 12) === 'WEBP';
          if (!valid) fail(502, 'INVALID_RESPONSE');
          binaryType = type;
          return bytes;
        }
      }
      const match = /^\/api\/zlibrary\/(search|login|logout|session|download)$/.exec(request.url ?? '');
      if (!match) fail((request.url ?? '').includes('?') ? 400 : 404,
        (request.url ?? '').includes('?') ? 'INVALID_REQUEST' : 'NOT_FOUND');
      if (request.method !== 'POST') {
        response.setHeader('Allow', 'POST');
        fail(405, 'METHOD_NOT_ALLOWED');
      }
      const operation = match[1];
      const body = await localBody(request, signal);
      signal.throwIfAborted();
      schema(operation, body);
      cleanup();
      if (operation === 'download' || operation === 'logout' || operation === 'session') {
        const bearer = /^Bearer ([A-Za-z0-9_-]{43})$/.exec(request.headers.authorization ?? '');
        token = bearer?.[1];
        if (operation === 'session') {
          const cookies = (request.headers.cookie ?? '').split(';').map((part) => part.trim())
            .filter((part) => part.startsWith(`${SESSION_COOKIE}=`));
          token = cookies.length === 1 ? cookies[0].slice(SESSION_COOKIE.length + 1) : undefined;
          if (typeof token !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(token)) token = undefined;
        }
        session = sessions.get(token);
        requireSession(operation !== 'download');
      }
      if (operation === 'session') {
        if (initialLoginGeneration !== loginGeneration) fail(401, 'AUTH_REQUIRED');
        const renewed = { ...session, expires: now() + SESSION_MS, rememberedUntil: now() + REMEMBERED_MS };
        const next = new Map(sessions);
        next.set(token, renewed);
        persist(next);
        Object.assign(session, renewed);
        cookieToken = token;
        renewing = true;
        return { session: token, expiresIn: SESSION_MS / 1000 };
      }
      if (operation === 'logout') {
        revoke(token);
        // Revocation invalidates the cookie; late responses must not erase a newer login.
        return { success: 1 };
      }
      if (operation === 'login') {
        if (attempts.length >= 5) fail(429, 'RATE_LIMITED');
        attempts.push(now());
        if (sessions.size + pendingLogins >= 32) fail(429, 'SESSION_LIMIT');
        pendingLogins++;
        reservedLogin = true;
        try {
          const result = await remoteJson('/eapi/user/login', {
            method: 'POST', headers: { Accept: 'application/json', 'Content-Type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams({ email: body.email, password: body.password }).toString(),
          });
          signal.throwIfAborted();
          if (result.success !== 1) fail(401, 'AUTH_REQUIRED');
          const user = result.user;
          const id = user?.id;
          if (!record(user) || !(positive(id) || (typeof id === 'string' && /^[1-9][0-9]{0,31}$/.test(id)))
            || typeof user.remix_userkey !== 'string' || !/^[A-Za-z0-9_-]{1,512}$/.test(user.remix_userkey)) {
            fail(502, 'INVALID_RESPONSE');
          }
          const localToken = randomBytes(32).toString('base64url');
          const localSession = { id: String(id), key: user.remix_userkey,
            expires: now() + SESSION_MS, rememberedUntil: now() + REMEMBERED_MS };
          const next = new Map(sessions);
          next.set(localToken, localSession);
          persist(next);
          sessions = next;
          token = localToken;
          session = localSession;
          cookieToken = localToken;
          loginGeneration++;
          return { session: localToken };
        } finally { releaseLogin(); }
      }
      if (operation === 'search') {
        const result = await remoteJson('/eapi/book/search', {
          method: 'POST', headers: { Accept: 'application/json', 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({ message: body.query.trim(), page: String(body.page), limit: '20', 'extensions[]': 'epub' }).toString(),
        });
        if (result.success !== 1 || !Array.isArray(result.books)) fail(502, 'INVALID_RESPONSE');
        const books = result.books.filter((book) => record(book) && positive(book.id) && hash(book.hash)
          && typeof book.extension === 'string' && book.extension.toLowerCase() === 'epub'
          && text(book.title, 1000) && text(book.author, 500, true)).slice(0, 20).map((book) => {
          const metadata = { id: book.id, hash: book.hash, title: book.title, author: book.author, extension: 'epub' };
          try { metadata.coverUrl = coverUrl(book.cover).href; }
          catch { /* Missing or untrusted covers use the existing illustrated fallback. */ }
          return metadata;
        });
        const pagination = result.pagination;
        let hasNext = result.books.length >= 20;
        if (record(pagination) && positive(pagination.current) && pagination.current === body.page) {
          const knownPages = positive(pagination.total_pages) && pagination.total_pages >= pagination.current;
          const validTotal = pagination.total_pages == null || knownPages;
          if (validTotal && (pagination.next === false || pagination.next === null)) hasNext = false;
          else if (validTotal && positive(pagination.next) && pagination.next === body.page + 1
            && (!knownPages || pagination.next <= pagination.total_pages)) hasNext = true;
          else if (knownPages && pagination.next === undefined) hasNext = pagination.current < pagination.total_pages;
        }
        return { books, hasNext };
      }
      const cookie = `remix_userid=${session.id}; remix_userkey=${session.key}; siteLanguageV2=en`;
      const result = await remoteJson(`/eapi/book/${body.id}/${body.hash}/file`, {
        method: 'GET', headers: { Accept: 'application/json', Cookie: cookie },
      });
      requireSession();
      if (result.success !== 1
        || (result.allowDownload !== undefined && result.allowDownload !== true)
        || (result.file?.allowDownload !== undefined && result.file.allowDownload !== true)) fail(403, 'DOWNLOAD_DENIED');
      if (!record(result.file) || typeof result.file.extension !== 'string'
        || result.file.extension.toLowerCase() !== 'epub') fail(403, 'DOWNLOAD_DENIED');
      let url = fileUrl(result.file.downloadLink);
      for (let redirects = 0; ; redirects++) {
        requireSession();
        const headers = { Accept: 'application/epub+zip, application/octet-stream' };
        if (url.hostname === 'z-library.biz') headers.Cookie = cookie;
        const upstream = await fetchRemote(url.href, { method: 'GET', headers });
        if (REDIRECTS.has(upstream.status)) {
          cancelBody(upstream.body);
          if (redirects >= 3) fail(502, 'INVALID_RESPONSE');
          url = fileUrl(upstream.headers.get('location'), url);
          continue;
        }
        if (upstream.status === 401 && url.hostname === 'z-library.biz') {
          cancelBody(upstream.body);
          revoke(token);
          fail(401, 'AUTH_REQUIRED');
        }
        const jsonType = /^application\/json(?:\s*;|$)/i.test(upstream.headers.get('content-type') ?? '');
        if (jsonType) await readJson(upstream, url.hostname === 'z-library.biz');
        if (!upstream.ok) {
          cancelBody(upstream.body);
          fail(502, 'UPSTREAM_UNAVAILABLE');
        }
        if (jsonType) fail(502, 'INVALID_RESPONSE');
        const bytes = await bounded(upstream, FILE_LIMIT, signal, cancelBody);
        requireSession();
        if (bytes.length < 4 || !bytes.subarray(0, 4).equals(Buffer.from([0x50, 0x4b, 0x03, 0x04]))) fail(502, 'INVALID_RESPONSE');
        return bytes;
      }
    };
    const work = run();
    try {
      const result = await Promise.race([work, stopped]);
      signal.throwIfAborted();
      if (Buffer.isBuffer(result) && binaryType === 'application/epub+zip') requireSession();
      if (cookieToken) {
        requireSession(true);
        if (renewing && initialLoginGeneration !== loginGeneration) fail(401, 'AUTH_REQUIRED');
        response.setHeader('Set-Cookie', `${SESSION_COOKIE}=${cookieToken}; Max-Age=${REMEMBERED_MS / 1000}; ${COOKIE_OPTIONS}`);
      }
      send(response, 200, result, Buffer.isBuffer(result) ? binaryType : undefined);
    } catch (error) {
      const safe = error instanceof ApiError ? error : new ApiError(502, 'UPSTREAM_UNAVAILABLE');
      send(response, safe.status, { error: safe.message, code: safe.code });
    } finally {
      releaseLogin();
      clearTimeout(timer);
      response.off('close', disconnected);
      request.off('aborted', disconnected);
      controller.abort(new ApiError(400, 'INVALID_REQUEST'));
      if (!request.readableEnded) request.resume();
      // A timeout/abort wins the response race, not the lifetime of the real work.
      await work.catch(() => {});
      await Promise.all(cancellations);
      active.delete(controller);
      finished();
    }
  };
  handler.close = () => {
    if (closing) return closing;
    closed = true;
    for (const controller of active.keys()) controller.abort(new ApiError(502, 'UPSTREAM_UNAVAILABLE'));
    closing = Promise.all(active.values()).then(async () => {
      sessions.clear();
      attempts = [];
      await sessionStore?.close?.();
      if (sessionStore) STORE_OWNERS.delete(sessionStore);
    });
    return closing;
  };
  return handler;
}
