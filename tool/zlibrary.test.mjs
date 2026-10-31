import assert from 'node:assert/strict';
import { once } from 'node:events';
import { chmod, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import http from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, test } from 'node:test';
import { createServer, validateUpstream } from './serve.mjs';
import { createZlibraryHandler } from './zlibrary.mjs';
import { createZlibrarySessionStore } from './zlibrary_session_store.mjs';

const MiB = 1024 * 1024;
const DAY = 24 * 60 * 60 * 1000;
const PREFIX = '/api/zlibrary/';
const EMAIL = 'fixture@example.invalid';
const PASSWORD = 'fixture-password-not-real';
const KEY = 'fixture_remix_key';
const USER_ID = 735192;
const EPUB = Buffer.from([0x50, 0x4b, 0x03, 0x04, 1, 2, 3, 4]);
const BOOK = { id: 42, hash: 'abc123', title: 'Livro', author: 'Autor', extension: 'epub' };
const FILE_URL = 'https://download.cdn-zlib.sk/book.epub?signature=private-signed-fixture';
const COVER_URL = 'https://s3proxy-alp2-covers.cdn-zlib.sk/covers299/collections/fiction/cover.jpg';
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]);
let root;

before(async () => {
  root = await mkdtemp(join(tmpdir(), 'leitura-zlibrary-'));
  await writeFile(join(root, 'index.html'), '<html>fixture</html>');
});
after(async () => { await rm(root, { recursive: true, force: true }); });

function json(value, options = {}) {
  return new Response(JSON.stringify(value), { ...options, headers: { 'Content-Type': 'application/json', ...options.headers } });
}
function loginResponse() { return json({ success: 1, user: { id: USER_ID, remix_userkey: KEY, email: EMAIL } }); }
function fileResponse(overrides = {}) {
  return json({ success: 1, file: { extension: 'epub', downloadLink: FILE_URL }, ...overrides });
}
function deferred() {
  let resolve;
  const promise = new Promise((accept) => { resolve = accept; });
  return { promise, resolve };
}
function tracked(status = 200, headers = {}, first) {
  const state = { cancelled: false };
  state.response = new Response(new ReadableStream({
    start(controller) { if (first) controller.enqueue(first); },
    cancel() { state.cancelled = true; },
  }), { status, headers });
  return state;
}
async function start(t, { integration = false, ...options } = {}) {
  const fetchImpl = options.fetchImpl ?? (() => { throw new Error('Unexpected network call.'); });
  let handler;
  const server = integration ? await createServer({ staticRoot: root, ...options, fetchImpl })
    : http.createServer(handler = createZlibraryHandler({ ...options, fetchImpl }));
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(async () => {
    const closing = handler?.close();
    server.closeAllConnections();
    await new Promise((accept) => server.close(accept));
    await closing;
  });
  const base = `http://127.0.0.1:${server.address().port}`;
  return {
    base, server, handler,
    async post(operation, body = {}, token, extraHeaders = {}) {
      return fetch(`${base}${PREFIX}${operation}`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json', 'X-Leitura-Client': '1',
          ...(token ? { Authorization: `Bearer ${token}` } : {}), ...extraHeaders,
        },
        body: JSON.stringify(body),
      });
    },
  };
}
async function login(app) {
  const response = await app.post('login', { email: EMAIL, password: PASSWORD });
  assert.equal(response.status, 200);
  const result = await response.json();
  assert.deepEqual(Object.keys(result), ['session']);
  assert.match(result.session, /^[A-Za-z0-9_-]{43}$/);
  return result.session;
}
async function error(response, status, code) {
  assert.equal(response.status, status);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(response.headers.get('access-control-allow-origin'), null);
  assert.equal(response.headers.get('set-cookie'), null);
  const body = await response.json();
  assert.deepEqual(Object.keys(body).sort(), ['code', 'error']);
  assert.equal(body.code, code);
  assert.equal(typeof body.error, 'string');
  assert.doesNotMatch(JSON.stringify(body), new RegExp(`${KEY}|${PASSWORD}|${EMAIL}|${USER_ID}|https:|signature=`));
  return body;
}
function raw(app, { path = `${PREFIX}search`, method = 'POST', headers = {}, body = '{"query":"","page":1}' } = {}) {
  return new Promise((resolve, reject) => {
    const requestHeaders = { Host: new URL(app.base).host, 'Content-Type': 'application/json', 'X-Leitura-Client': '1', ...headers };
    const request = http.request(app.base, {
      path, method,
      headers: Object.entries(requestHeaders).flatMap(([name, value]) =>
        (Array.isArray(value) ? value : [value]).flatMap((item) => [name, item])),
    }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('error', reject);
      response.on('end', () => resolve({
        status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks).toString(),
      }));
    });
    request.on('error', reject);
    request.end(body);
  });
}

test('createServer integrates search/login/download/logout without changing proxy allowlist', async (t) => {
  const calls = [];
  const app = await start(t, {
    integration: true,
    fetchImpl: async (url, options) => {
      calls.push({ url, options });
      assert.equal(options.redirect, 'manual');
      assert.equal(options.credentials, 'omit');
      assert.equal(options.headers.Authorization, undefined);
      assert.equal(options.headers['X-Leitura-Client'], undefined);
      if (url.endsWith('/user/login')) {
        assert.equal(options.method, 'POST');
        assert.deepEqual(Object.fromEntries(new URLSearchParams(options.body)), { email: EMAIL, password: PASSWORD });
        assert.equal(options.headers.Cookie, undefined);
        return loginResponse();
      }
      if (url.endsWith('/book/search')) {
        assert.equal(options.method, 'POST');
        assert.deepEqual(Object.fromEntries(new URLSearchParams(options.body)), {
          message: 'historia', page: '2', limit: '20', 'extensions[]': 'epub',
        });
        assert.equal(options.headers.Cookie, undefined);
        return json({ success: 1, books: [{ ...BOOK, email: EMAIL, remix_userkey: KEY, downloadLink: FILE_URL }],
          pagination: { current: 2, next: 3, total_pages: 3 }, user: { id: USER_ID, remix_userkey: KEY } });
      }
      if (url.endsWith('/42/abc123/file')) {
        assert.equal(options.method, 'GET');
        assert.deepEqual(options.headers, {
          Accept: 'application/json', Cookie: `remix_userid=${USER_ID}; remix_userkey=${KEY}; siteLanguageV2=en`,
        });
        return fileResponse();
      }
      assert.equal(url, FILE_URL);
      assert.deepEqual(options.headers, { Accept: 'application/epub+zip, application/octet-stream' });
      return new Response(EPUB, { headers: { 'Set-Cookie': KEY, 'Content-Encoding': 'gzip', 'Content-Length': '1' } });
    },
  });
  const token = await login(app);
  assert.notEqual(token, KEY);
  const search = await app.post('search', { query: ' historia ', page: 2 }, token, { Cookie: 'private=client', Origin: app.base });
  assert.equal(search.status, 200);
  assert.equal(search.headers.get('cache-control'), 'no-store');
  assert.deepEqual(await search.json(), { books: [BOOK], hasNext: true });
  const downloaded = await app.post('download', { id: 42, hash: 'abc123' }, token, { Cookie: 'private=client', Range: 'bytes=0-1' });
  assert.equal(downloaded.status, 200);
  assert.equal(downloaded.headers.get('content-type'), 'application/epub+zip');
  assert.equal(downloaded.headers.get('cache-control'), 'no-store');
  assert.equal(downloaded.headers.get('set-cookie'), null);
  assert.equal(downloaded.headers.get('content-encoding'), null);
  assert.equal(downloaded.headers.get('content-length'), String(EPUB.length));
  assert.deepEqual(Buffer.from(await downloaded.arrayBuffer()), EPUB);
  const logout = await app.post('logout', {}, token);
  assert.equal(logout.status, 200);
  assert.deepEqual(await logout.json(), { success: 1 });
  await error(await app.post('download', { id: 42, hash: 'abc123' }, token), 401, 'AUTH_REQUIRED');
  await error(await app.post('logout', {}, token), 401, 'AUTH_REQUIRED');
  assert.equal(calls.length, 4);
  assert.throws(() => validateUpstream(FILE_URL));
  assert.throws(() => validateUpstream('https://z-library.biz/eapi/book/search'));
});

test('browser session restoration renews access and the HttpOnly remembered cookie without remote calls', async (t) => {
  let clock = 10_000;
  let calls = 0;
  const app = await start(t, { now: () => clock, fetchImpl: async () => {
    calls++;
    return loginResponse();
  } });
  const response = await app.post('login', { email: EMAIL, password: PASSWORD });
  assert.equal(response.status, 200);
  const { session: token } = await response.json();
  const header = response.headers.get('set-cookie');
  const cookie = header.split(';')[0];
  assert.equal(cookie, `leitura_zlibrary_session=${token}`);
  assert.match(header, /Max-Age=2592000/);
  assert.match(header, /Path=\/api\/zlibrary\//);
  assert.match(header, /HttpOnly/);
  assert.match(header, /SameSite=Strict/);
  assert.doesNotMatch(header, new RegExp(`${KEY}|${PASSWORD}|${EMAIL}|${USER_ID}`));
  clock += 31 * 60_000;
  await error(await app.post('download', { id: 42, hash: 'abc123' }, token), 401, 'AUTH_REQUIRED');
  const restored = await app.post('session', {}, undefined, { Cookie: cookie });
  assert.equal(restored.status, 200);
  assert.equal(restored.headers.get('set-cookie'), header);
  assert.deepEqual(await restored.json(), { session: token, expiresIn: 30 * 60 });
  clock += 30 * DAY;
  await error(await app.post('session', {}, undefined, { Cookie: cookie }), 401, 'AUTH_REQUIRED');
  assert.equal(calls, 1);
});

test('logout revokes restoration without overwriting a newer browser cookie', async (t) => {
  const app = await start(t, { integration: true, fetchImpl: async () => loginResponse() });
  const token = await login(app);
  const cookie = `leitura_zlibrary_session=${token}`;
  const logout = await app.post('logout', {}, token, { Cookie: cookie });
  assert.equal(logout.status, 200);
  assert.equal(logout.headers.get('set-cookie'), null);
  await error(await app.post('session', {}, undefined, { Cookie: cookie }), 401, 'AUTH_REQUIRED');
});

test('logging out an older tab leaves the newer browser session restorable', async (t) => {
  const app = await start(t, { fetchImpl: async () => loginResponse() });
  const oldToken = await login(app);
  const newToken = await login(app);
  const cookie = `leitura_zlibrary_session=${newToken}`;
  const logout = await app.post('logout', {}, oldToken, { Cookie: cookie });
  assert.equal(logout.status, 200);
  assert.equal(logout.headers.get('set-cookie'), null);
  const restored = await app.post('session', {}, undefined, { Cookie: cookie });
  assert.equal(restored.status, 200);
  assert.equal((await restored.json()).session, newToken);
  await error(await app.post('session', {}, undefined, {
    Cookie: `leitura_zlibrary_session=${oldToken}`,
  }), 401, 'AUTH_REQUIRED');
});

test('session restoration rejects absent, forged, duplicate cookies, foreign origins and nonempty bodies', async (t) => {
  let calls = 0;
  const app = await start(t, { fetchImpl: async () => { calls++; return loginResponse(); } });
  const token = await login(app);
  const cookie = `leitura_zlibrary_session=${token}`;
  for (const Cookie of ['', 'other=value', 'leitura_zlibrary_session=bad',
    `leitura_zlibrary_session=${'a'.repeat(43)}`, `${cookie}; ${cookie}`]) {
    await error(await app.post('session', {}, undefined, { Cookie }), 401, 'AUTH_REQUIRED');
  }
  await error(await app.post('session', {}, token), 401, 'AUTH_REQUIRED');
  await error(await app.post('session', {}, undefined, { Cookie: cookie, Origin: 'https://evil.example' }), 403, 'FORBIDDEN');
  await error(await app.post('session', { session: token }, undefined, { Cookie: cookie }), 400, 'INVALID_REQUEST');
  const duplicate = await raw(app, { path: `${PREFIX}session`, body: '{}', headers: { Cookie: [cookie, cookie] } });
  assert.equal(duplicate.status, 400);
  assert.equal(calls, 1);
});

test('search is public, trims empty query, filters invalid metadata and caps output at 20', async (t) => {
  const invalid = [
    { ...BOOK, id: 0 }, { ...BOOK, id: '42' }, { ...BOOK, id: 1.5 }, { ...BOOK, hash: '../secret' },
    { ...BOOK, hash: 'x'.repeat(65) }, { ...BOOK, extension: 'pdf' }, { ...BOOK, extension: null },
    { ...BOOK, title: '' }, { ...BOOK, title: 'x'.repeat(1001) }, { ...BOOK, author: 'x'.repeat(501) },
    { ...BOOK, title: 'bad\nvalue' }, null,
  ];
  const app = await start(t, { fetchImpl: async (_url, options) => {
    assert.equal(new URLSearchParams(options.body).get('message'), '');
    assert.equal(options.headers.Cookie, undefined);
    assert.equal(options.headers.Authorization, undefined);
    return json({ success: 1, books: [...invalid, ...Array.from({ length: 25 }, (_, index) => ({ ...BOOK, id: index + 1, extension: 'EPUB', secret: KEY }))] });
  } });
  const response = await app.post('search', { query: '  ', page: 1 }, KEY);
  assert.equal(response.status, 200);
  const result = await response.json();
  assert.equal(result.books.length, 20);
  assert.equal(result.hasNext, true);
  assert.deepEqual(result.books[0], { ...BOOK, id: 1 });
  assert.doesNotMatch(JSON.stringify(result), new RegExp(KEY));
});

test('search preserves only approved public covers; invalid covers do not remove books', async (t) => {
  const covers = [COVER_URL, undefined, null, 42, '', FILE_URL, 'http://127.0.0.1/cover.jpg',
    COVER_URL + '?token=secret', COVER_URL + '#fragment', COVER_URL.replace('https://', 'https://user:password@')];
  const app = await start(t, { fetchImpl: async () => json({ success: 1,
    books: covers.map((cover, index) => ({ ...BOOK, id: index + 1, cover })),
  }) });
  const result = await (await app.post('search', { query: 'livro', page: 1 })).json();
  assert.equal(result.books.length, covers.length);
  assert.deepEqual(result.books[0], { ...BOOK, id: 1, coverUrl: COVER_URL });
  for (const book of result.books.slice(1)) assert.equal(Object.hasOwn(book, 'coverUrl'), false);
});

test('dedicated cover route returns bounded raster bytes without credentials or widening the proxy', async (t) => {
  const calls = [];
  const app = await start(t, { integration: true, fetchImpl: async (url, options) => {
    calls.push(url);
    assert.equal(options.method, 'GET');
    assert.equal(options.redirect, 'manual');
    assert.equal(options.credentials, 'omit');
    assert.deepEqual(options.headers, { Accept: 'image/jpeg, image/png, image/webp' });
    if (calls.length === 1) return new Response(null, { status: 302, headers: { Location: '/covers299/redirect.jpg' } });
    return new Response(JPEG, { headers: { 'Content-Type': 'image/jpeg; charset=binary', 'Set-Cookie': KEY } });
  } });
  const response = await fetch(`${app.base}${PREFIX}cover?url=${encodeURIComponent(COVER_URL)}`, {
    headers: { Origin: app.base, Cookie: 'private=client', Authorization: `Bearer ${KEY}`, Range: 'bytes=0-1' },
  });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('content-type'), 'image/jpeg');
  assert.equal(response.headers.get('content-length'), String(JPEG.length));
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(response.headers.get('cross-origin-resource-policy'), 'same-origin');
  assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
  assert.equal(response.headers.get('set-cookie'), null);
  assert.equal(response.headers.get('access-control-allow-origin'), null);
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), JPEG);
  assert.deepEqual(calls, [COVER_URL, new URL('/covers299/redirect.jpg', COVER_URL).href]);
  assert.throws(() => validateUpstream(COVER_URL));
});

test('cover URL, query, method and local origin guards reject untrusted requests before fetching', async (t) => {
  let calls = 0;
  const app = await start(t, { fetchImpl: async () => { calls++; throw new Error('No fetch expected'); } });
  for (const url of [
    FILE_URL, 'https://z-library.biz/eapi/user/profile', 'http://127.0.0.1/cover.jpg',
    COVER_URL.replace('https:', 'http:'), COVER_URL.replace('.sk/', '.sk.evil.test/'),
    COVER_URL.replace('.sk/', '.sk:444/'), COVER_URL.replace('https://', 'https://user:password@'),
    COVER_URL.replace('https://', 'https://@'), COVER_URL + '?secret=1', COVER_URL + '#secret',
    COVER_URL.replace('/covers299/', '/private/'), COVER_URL.replace('.jpg', '.svg'),
    COVER_URL.replace('/collections/', '/collections\\'), COVER_URL + '\n',
  ]) {
    await error(await fetch(`${app.base}${PREFIX}cover?url=${encodeURIComponent(url)}`), 502, 'HOST_NOT_ALLOWED');
  }
  for (const query of ['', 'url=', 'other=x', `url=${encodeURIComponent(COVER_URL)}&url=${encodeURIComponent(COVER_URL)}`,
    `url=${encodeURIComponent(COVER_URL)}&extra=1`]) {
    const response = await fetch(`${app.base}${PREFIX}cover?${query}`);
    assert.notEqual(response.status, 200);
  }
  await error(await fetch(`${app.base}${PREFIX}cover?url=${encodeURIComponent(COVER_URL)}`, { method: 'POST' }),
    405, 'METHOD_NOT_ALLOWED');
  for (const headers of [{ Origin: 'https://evil.test' }, { 'Sec-Fetch-Site': 'cross-site' },
    { Host: 'evil.test' }]) {
    const response = await raw(app, { path: `${PREFIX}cover?url=${encodeURIComponent(COVER_URL)}`,
      method: 'GET', body: '', headers });
    assert.equal(response.status, 403, JSON.stringify(headers));
    assert.equal(JSON.parse(response.body).code, 'FORBIDDEN');
  }
  assert.equal(calls, 0);
});

test('cover redirects are revalidated and capped, never following foreign or authenticated destinations', async (t) => {
  for (const location of [FILE_URL, 'https://z-library.biz/eapi/user/profile', 'http://127.0.0.1/private',
    COVER_URL + '?token=secret', COVER_URL.replace('https://', 'https://user:password@'), null]) {
    let calls = 0;
    const app = await start(t, { fetchImpl: async () => {
      calls++;
      return new Response(null, { status: 302, headers: location === null ? {} : { Location: location } });
    } });
    await error(await fetch(`${app.base}${PREFIX}cover?url=${encodeURIComponent(COVER_URL)}`), 502, 'HOST_NOT_ALLOWED');
    assert.equal(calls, 1);
  }
  let calls = 0;
  const app = await start(t, { fetchImpl: async () => {
    calls++;
    return new Response(null, { status: 302, headers: { Location: COVER_URL } });
  } });
  await error(await fetch(`${app.base}${PREFIX}cover?url=${encodeURIComponent(COVER_URL)}`), 502, 'INVALID_RESPONSE');
  assert.equal(calls, 4);
});

test('cover responses require an allowed MIME, matching signature and at most 2 MiB', async (t) => {
  for (const [type, bytes, status] of [
    ['image/jpeg', JPEG, 200],
    ['image/png', Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), 200],
    ['image/webp', Buffer.from('RIFFxxxxWEBP'), 200],
    ['image/jpeg', Buffer.from('<html>not an image</html>'), 502],
    ['image/png', JPEG, 502], ['image/webp', JPEG, 502],
    ['image/jpeg', Buffer.alloc(0), 502], ['image/svg+xml', Buffer.from('<svg/>'), 502],
    ['text/html', JPEG, 502], ['application/octet-stream', JPEG, 502],
    ['image/jpeg', Buffer.alloc(2 * MiB + 1), 413],
  ]) {
    const app = await start(t, { fetchImpl: async () => new Response(bytes, { headers: { 'Content-Type': type } }) });
    const response = await fetch(`${app.base}${PREFIX}cover?url=${encodeURIComponent(COVER_URL)}`);
    assert.equal(response.status, status, type);
    if (status === 200) assert.deepEqual(Buffer.from(await response.arrayBuffer()), bytes);
    else await error(response, status, status === 413 ? 'TOO_LARGE' : 'INVALID_RESPONSE');
  }
  const upstream = tracked(200, { 'Content-Type': 'image/jpeg', 'Content-Length': String(2 * MiB + 1) });
  const app = await start(t, { fetchImpl: async () => upstream.response });
  await error(await fetch(`${app.base}${PREFIX}cover?url=${encodeURIComponent(COVER_URL)}`), 413, 'TOO_LARGE');
  assert.equal(upstream.cancelled, true);
});

test('cover failures and timeouts return safe errors without requiring or invalidating login', async (t) => {
  const unavailable = await start(t, { fetchImpl: async () => new Response(null, { status: 404 }) });
  await error(await fetch(`${unavailable.base}${PREFIX}cover?url=${encodeURIComponent(COVER_URL)}`), 502, 'UPSTREAM_UNAVAILABLE');
  let signal;
  const release = deferred();
  const slow = await start(t, { timeoutMs: 30, fetchImpl: async (_url, options) => {
    signal = options.signal;
    await release.promise;
    return new Response(JPEG);
  } });
  await error(await fetch(`${slow.base}${PREFIX}cover?url=${encodeURIComponent(COVER_URL)}`), 504, 'TIMEOUT');
  assert.equal(signal.aborted, true);
  release.resolve();
});

test('pagination validates real API current/next fields and never trusts remote URLs', async (t) => {
  for (const [pagination, count, expected, page = 1] of [
    [{ limit: 1, current: 1, before: false, next: 2, total_items: 500, total_pages: 500 }, 1, true],
    [{ current: 500, next: false, total_pages: 500 }, 20, false, 500],
    [{ current: 1, next: null, total_pages: 1 }, 20, false],
    [{ current: 1, total_pages: 1 }, 20, false],
    [{ current: 1, total_pages: 2 }, 1, true],
    [{ current: 1, next: 2 }, 1, true],
    [{ current: 1, next: null }, 20, false],
    [{ current: 2, next: 3, total_pages: 3 }, 1, false],
    [{ current: '1', next: 2, total_pages: 2 }, 1, false],
    [{ current: 0, next: 2, total_pages: 2 }, 1, false],
    [{ current: 1, next: 2, total_pages: 1 }, 1, false],
    [{ current: 1, next: 3, total_pages: 3 }, 1, false],
    [{ current: 1, next: '2', total_pages: 2 }, 1, false],
    [{ current: 1, next: 0, total_pages: 2 }, 20, true],
    [{ current: 1, next: 1.5, total_pages: 2 }, 1, false],
    [{ current: 1, next: 2, total_pages: -1 }, 1, false],
    [{ current: 1, next: 2, total_pages: '2' }, 1, false],
    [{ current: 1, next: 2, total_pages: Number.MAX_SAFE_INTEGER + 1 }, 1, false],
    [{ current: 1, next: 'http://127.0.0.1/private', total_pages: 2 }, 1, false],
    [{ next: 'http://127.0.0.1/private' }, 1, false],
    [{ current_page: 1, next: 2, total_pages: 2 }, 1, false],
    [null, 0, false],
  ]) {
    let calls = 0;
    const app = await start(t, { fetchImpl: async () => {
      calls++;
      return json({ success: 1, books: Array(count).fill(BOOK), pagination });
    } });
    const result = await (await app.post('search', { query: '', page })).json();
    assert.equal(result.hasNext, expected, JSON.stringify(pagination));
    assert.equal(calls, 1);
  }
});

test('regression: pagination fallback counts raw records before EPUB filtering and truncation', async (t) => {
  for (const [count, pagination, expected] of [
    [19, undefined, false], [20, undefined, true], [21, undefined, true], [40, undefined, true],
    [20, { current: 2, next: 3 }, true], [20, { current: 1, next: false, total_pages: 1 }, false],
  ]) {
    const records = Array.from({ length: count }, (_, index) => index === 0 ? BOOK
      : index % 2 === 0 ? { ...BOOK, extension: 'pdf' } : { ...BOOK, hash: '../invalid' });
    const app = await start(t, { fetchImpl: async () => json({ success: 1, books: records, pagination }) });
    const response = await app.post('search', { query: '', page: 1 });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { books: [BOOK], hasNext: expected });
  }
  const app = await start(t, { fetchImpl: async () => json({ success: 1, books: Array(20).fill(null) }) });
  assert.deepEqual(await (await app.post('search', { query: '', page: 1 })).json(), { books: [], hasNext: true });
});

test('local guards reject CSRF, foreign hosts/ports/origins and unexpected content', async (t) => {
  let calls = 0;
  const app = await start(t, { fetchImpl: () => { calls++; throw new Error('must not fetch'); } });
  const port = app.server.address().port;
  for (const headers of [
    { Host: 'evil.example' }, { Host: `evil.example:${port}` }, { Host: `localhost:${port + 1}` },
    { Host: `127.0.0.2:${port}` }, { Host: `localhost.:${port}` }, { Host: '127.0.0.1' },
    { Origin: 'null' }, { Origin: 'https://127.0.0.1:' + port }, { Origin: 'http://localhost:' + port },
    { Origin: app.base + '/' }, { 'Sec-Fetch-Site': 'cross-site' },
  ]) {
    const result = await raw(app, { headers });
    assert.equal(result.status, 403, JSON.stringify(headers));
    assert.equal(JSON.parse(result.body).code, 'FORBIDDEN');
    assert.equal(result.headers['cache-control'], 'no-store');
    assert.equal(result.headers['access-control-allow-origin'], undefined);
  }
  for (const headers of [
    { 'Content-Type': 'text/plain' }, { 'Content-Type': 'application/x-www-form-urlencoded' },
    { 'Content-Type': 'application/json; charset=latin1' }, { 'Content-Type': '' },
    { 'X-Leitura-Client': '' }, { 'X-Leitura-Client': '2' }, { 'Content-Encoding': 'gzip' },
  ]) {
    assert.equal((await raw(app, { headers })).status, 400);
  }
  assert.equal(calls, 0);
});

test('loopback Host variants work, duplicate security headers do not', async (t) => {
  const app = await start(t, { fetchImpl: async () => json({ success: 1, books: [] }) });
  const port = app.server.address().port;
  for (const hostname of ['localhost', '127.0.0.1', '[::1]']) {
    const host = `${hostname}:${port}`;
    assert.equal((await raw(app, { headers: { Host: host, Origin: `http://${host}` } })).status, 200);
  }
  for (const headers of [
    { Host: [`127.0.0.1:${port}`, `localhost:${port}`] },
    { Authorization: ['Bearer a', 'Bearer b'] }, { Origin: [app.base, app.base] },
  ]) assert.equal((await raw(app, { headers })).status, 400);
});

test('strict routes, methods and schemas reject invalid local requests without upstream work', async (t) => {
  const app = await start(t);
  for (const [operation, value] of [
    ['search', {}], ['search', { query: '', page: 0 }], ['search', { query: '', page: 1.1 }],
    ['search', { query: '', page: '1' }], ['search', { query: 1, page: 1 }],
    ['search', { query: 'x'.repeat(1001), page: 1 }], ['search', { query: '', page: 1, url: FILE_URL }],
    ['search', { query: '', page: Number.MAX_SAFE_INTEGER + 1 }],
    ['search', []], ['search', null], ['search', { query: '', page: 1, __proto__: null, constructor: 'bad' }],
    ['login', { email: EMAIL, password: '' }], ['login', { email: 'invalid', password: PASSWORD }],
    ['login', { email: EMAIL, password: 'x'.repeat(1025) }], ['login', { email: EMAIL, password: PASSWORD, cookie: KEY }],
    ['download', { id: -1, hash: 'abc' }], ['download', { id: '1', hash: 'abc' }],
    ['download', { id: 1, hash: '../' }], ['download', { id: 1, hash: '' }],
    ['logout', { session: KEY }],
  ]) await error(await app.post(operation, value), 400, 'INVALID_REQUEST');
  for (const path of [
    `${PREFIX}search?x=1`, `${PREFIX}search?`, `${PREFIX}search/`, `${PREFIX}login/extra`,
    `${PREFIX}%73earch`, `${PREFIX}arbitrary`, `${PREFIX}download#fragment`, '/api/zlibrary',
  ]) {
    const result = await raw(app, { path });
    assert.equal(result.status, path.includes('?') ? 400 : 404, path);
    assert.equal(result.headers['cache-control'], 'no-store');
  }
  for (const method of ['GET', 'HEAD', 'OPTIONS', 'PUT']) {
    const result = await raw(app, { method, body: '' });
    assert.equal(result.status, 405, method);
    assert.equal(result.headers.allow, 'POST');
    assert.equal(result.headers['cache-control'], 'no-store');
  }
  for (const body of ['invalid', '', '{', '{"query":"","page":NaN}']) {
    assert.equal((await raw(app, { body })).status, 400);
  }
});

test('local body limit checks declared and streamed sizes; exactly 16 KiB works', async (t) => {
  const app = await start(t, { fetchImpl: async () => json({ success: 1, books: [] }) });
  const body = '{"query":"","page":1}';
  const atLimit = body + ' '.repeat(16 * 1024 - Buffer.byteLength(body));
  assert.equal((await raw(app, { body: atLimit })).status, 200);
  for (const headers of [{ 'Content-Length': String(16 * 1024 + 1) }, { 'Transfer-Encoding': 'chunked' }]) {
    const result = await raw(app, { headers, body: atLimit + ' ' });
    assert.equal(result.status, 413);
    assert.equal(JSON.parse(result.body).code, 'TOO_LARGE');
  }
});

test('missing, invented and expired local sessions never reach upstream', async (t) => {
  let clock = 1000;
  let calls = 0;
  const app = await start(t, { now: () => clock, fetchImpl: async () => { calls++; return loginResponse(); } });
  await error(await app.post('download', { id: 42, hash: 'abc123' }), 401, 'AUTH_REQUIRED');
  await error(await app.post('logout', {}, 'x'.repeat(43)), 401, 'AUTH_REQUIRED');
  const token = await login(app);
  clock += 30 * 60 * 1000;
  await error(await app.post('download', { id: 42, hash: 'abc123' }, token), 401, 'AUTH_REQUIRED');
  assert.equal((await app.post('logout', {}, token)).status, 200);
  assert.equal(calls, 1);
});

test('successful requests do not renew the absolute 30 minute expiry', async (t) => {
  let clock = 0;
  let calls = 0;
  const app = await start(t, { now: () => clock, fetchImpl: async (url) => {
    calls++;
    if (url.endsWith('/login')) return loginResponse();
    if (url.endsWith('/file')) return fileResponse();
    return new Response(EPUB);
  } });
  const token = await login(app);
  clock = 30 * 60 * 1000 - 1;
  assert.equal((await app.post('download', { id: 42, hash: 'abc123' }, token)).status, 200);
  clock++;
  await error(await app.post('download', { id: 42, hash: 'abc123' }, token), 401, 'AUTH_REQUIRED');
  assert.equal(calls, 3);
});

test('login rate limit is per instance, includes failed attempts and resets lazily at one minute', async (t) => {
  let clock = 0;
  let calls = 0;
  const app = await start(t, { now: () => clock, fetchImpl: async () => {
    calls++;
    return json({ success: 0, message: `${EMAIL} ${PASSWORD} ${KEY}` });
  } });
  for (let index = 0; index < 5; index++) await error(await app.post('login', { email: EMAIL, password: PASSWORD }), 401, 'AUTH_REQUIRED');
  await error(await app.post('login', { email: EMAIL, password: PASSWORD }), 429, 'RATE_LIMITED');
  assert.equal(calls, 5);
  const other = await start(t, { fetchImpl: async () => loginResponse() });
  await login(other);
  clock = 60_000;
  await error(await app.post('login', { email: EMAIL, password: PASSWORD }), 401, 'AUTH_REQUIRED');
  assert.equal(calls, 6);
});

test('32 session cap never evicts an active session and logout frees capacity', async (t) => {
  let clock = 0;
  let calls = 0;
  const app = await start(t, { now: () => clock, fetchImpl: async () => { calls++; return loginResponse(); } });
  const tokens = [];
  for (let index = 0; index < 32; index++) {
    if (index % 5 === 0) clock += 60_000;
    tokens.push(await login(app));
  }
  assert.equal(new Set(tokens).size, 32);
  clock += 60_000;
  await error(await app.post('login', { email: EMAIL, password: PASSWORD }), 429, 'SESSION_LIMIT');
  assert.equal(calls, 32);
  assert.equal((await app.post('logout', {}, tokens[0])).status, 200);
  await login(app);
  assert.equal((await app.post('logout', {}, tokens[1])).status, 200);
  clock += 30 * 60 * 1000;
  await login(app);
});

test('pending logins reserve session capacity across concurrent requests', async (t) => {
  let clock = 0;
  let pause = false;
  let calls = 0;
  const entered = deferred();
  const release = deferred();
  const app = await start(t, { now: () => clock, fetchImpl: async () => {
    calls++;
    if (pause) { entered.resolve(); await release.promise; }
    return loginResponse();
  } });
  for (let index = 0; index < 31; index++) {
    if (index % 5 === 0) clock += 60_000;
    await login(app);
  }
  clock += 60_000;
  pause = true;
  const last = app.post('login', { email: EMAIL, password: PASSWORD });
  await entered.promise;
  await error(await app.post('login', { email: EMAIL, password: PASSWORD }), 429, 'SESSION_LIMIT');
  release.resolve();
  assert.equal((await last).status, 200);
  assert.equal(calls, 32);
});

test('timed out login releases its reserved slot and cannot create a ghost session on late success', async (t) => {
  let clock = 0;
  let pause = false;
  const release = deferred();
  const app = await start(t, { timeoutMs: 80, now: () => clock, fetchImpl: async () => {
    if (pause) await release.promise;
    return loginResponse();
  } });
  for (let index = 0; index < 31; index++) {
    if (index % 5 === 0) clock += 60_000;
    await login(app);
  }
  clock += 60_000;
  pause = true;
  await error(await app.post('login', { email: EMAIL, password: PASSWORD }), 504, 'TIMEOUT');
  pause = false;
  const last = await login(app);
  release.resolve();
  await new Promise((accept) => setImmediate(accept));
  assert.equal((await app.post('logout', {}, last)).status, 200);
  await login(app);
});

test('remote Please login or 401 deletes only the affected local session', async (t) => {
  for (const response of [() => json({ success: 0, message: `Please login ${KEY}` }),
    () => json({ success: 0, error: { message: 'Please login' } }),
    () => json({ message: KEY }, { status: 401 })]) {
    let calls = 0;
    const app = await start(t, { fetchImpl: async (url) => {
      calls++;
      return url.endsWith('/login') ? loginResponse() : response();
    } });
    const token = await login(app);
    const other = await login(app);
    await error(await app.post('download', { id: 42, hash: 'abc123' }, token), 401, 'AUTH_REQUIRED');
    await error(await app.post('download', { id: 42, hash: 'abc123' }, token), 401, 'AUTH_REQUIRED');
    assert.equal((await app.post('logout', {}, other)).status, 200);
    assert.equal(calls, 3);
  }
});

test('real HTTP 400 file JSON Please login removes the session and returns sanitized 401', async (t) => {
  let calls = 0;
  const app = await start(t, { fetchImpl: async (url) => {
    calls++;
    if (url.endsWith('/login')) return loginResponse();
    assert.equal(url, 'https://z-library.biz/eapi/book/42/abc123/file');
    return json({ success: 0, error: 'Please login' }, { status: 400, headers: { 'Set-Cookie': KEY } });
  } });
  const token = await login(app);
  const other = await login(app);
  await error(await app.post('download', { id: 42, hash: 'abc123' }, token), 401, 'AUTH_REQUIRED');
  await error(await app.post('download', { id: 42, hash: 'abc123' }, token), 401, 'AUTH_REQUIRED');
  await error(await app.post('logout', {}, token), 401, 'AUTH_REQUIRED');
  assert.equal((await app.post('logout', {}, other)).status, 200);
  assert.equal(calls, 3);
});

test('HTTP error JSON remains bounded; text Please login is not trusted or reflected', async (t) => {
  for (const kind of ['html', 'text', 'generic-json', 'bad-json', 'oversized-json']) {
    let calls = 0;
    let upstream;
    const app = await start(t, { fetchImpl: async (url) => {
      calls++;
      if (url.endsWith('/login')) return loginResponse();
      if (kind === 'oversized-json') {
        upstream = tracked(400, { 'Content-Type': 'application/json', 'Content-Length': String(4 * MiB + 1) });
        return upstream.response;
      }
      if (kind === 'generic-json') return json({ success: 0, error: `${EMAIL} ${KEY} ${FILE_URL}` }, { status: 400 });
      return new Response(kind === 'bad-json' ? '{' : `Please login ${KEY} ${PASSWORD} ${FILE_URL}`, {
        status: 400, headers: { 'Content-Type': { html: 'text/html', text: 'text/plain', 'bad-json': 'application/json' }[kind] },
      });
    } });
    const token = await login(app);
    await error(await app.post('download', { id: 42, hash: 'abc123' }, token), kind === 'oversized-json' ? 413 : 502,
      kind === 'oversized-json' ? 'TOO_LARGE' : kind === 'bad-json' ? 'INVALID_RESPONSE' : 'UPSTREAM_UNAVAILABLE');
    assert.equal((await app.post('logout', {}, token)).status, 200);
    assert.equal(calls, 2);
    if (upstream) assert.equal(upstream.cancelled, true);
  }
});

test('remote login requires exact success and safe user cookie fields', async (t) => {
  for (const value of [
    { success: true, user: { id: USER_ID, remix_userkey: KEY } },
    { success: '1', user: { id: USER_ID, remix_userkey: KEY } },
    { success: 1 }, { success: 1, user: { id: 0, remix_userkey: KEY } },
    { success: 1, user: { id: USER_ID, remix_userkey: 'bad; injected=value' } },
    { success: 1, user: { id: '1\r\nCookie: bad', remix_userkey: KEY } },
  ]) {
    const app = await start(t, { fetchImpl: async () => json(value) });
    await error(await app.post('login', { email: EMAIL, password: PASSWORD }), value.success !== 1 ? 401 : 502,
      value.success !== 1 ? 'AUTH_REQUIRED' : 'INVALID_RESPONSE');
  }
});

test('a file endpoint returning JSON Please login or same-host 401 invalidates the local session', async (t) => {
  for (const kind of ['json', '401']) {
    let calls = 0;
    const app = await start(t, { fetchImpl: async (url) => {
      calls++;
      if (url.endsWith('/login')) return loginResponse();
      if (url.endsWith('/file')) return fileResponse({ file: { extension: 'epub', downloadLink: 'https://z-library.biz/book.epub' } });
      return kind === 'json' ? json({ message: 'Please login', user: { remix_userkey: KEY } })
        : new Response(KEY, { status: 401 });
    } });
    const token = await login(app);
    await error(await app.post('download', { id: 42, hash: 'abc123' }, token), 401, 'AUTH_REQUIRED');
    await error(await app.post('download', { id: 42, hash: 'abc123' }, token), 401, 'AUTH_REQUIRED');
    assert.equal(calls, 3);
  }
});

test('regression: authenticated-host HTTP 401 revokes the session before parsing malformed JSON', async (t) => {
  for (const stage of ['metadata', 'file']) {
    let calls = 0;
    let cancelled = false;
    const app = await start(t, { fetchImpl: async (url) => {
      calls++;
      if (url.endsWith('/login')) return loginResponse();
      if (stage === 'file' && url.endsWith('/file')) {
        return fileResponse({ file: { extension: 'epub', downloadLink: 'https://z-library.biz/book.epub' } });
      }
      return new Response(new ReadableStream({
        start(controller) { controller.enqueue(Buffer.from(`{${KEY}`)); },
        pull(controller) { controller.close(); },
        cancel() { cancelled = true; },
      }), { status: 401, headers: { 'Content-Type': 'application/json' } });
    } });
    const token = await login(app);
    await error(await app.post('download', { id: 42, hash: 'abc123' }, token), 401, 'AUTH_REQUIRED');
    assert.equal(cancelled, true);
    await error(await app.post('download', { id: 42, hash: 'abc123' }, token), 401, 'AUTH_REQUIRED');
    await error(await app.post('logout', {}, token), 401, 'AUTH_REQUIRED');
    assert.equal(calls, stage === 'metadata' ? 2 : 3);
  }
});

test('regression: unauthenticated CDN Please login never revokes the local session or receives credentials', async (t) => {
  for (const status of [200, 400, 401, 503]) {
    let denied = true;
    let calls = 0;
    let cdnCalls = 0;
    const app = await start(t, { fetchImpl: async (url, options) => {
      calls++;
      if (url.endsWith('/login')) return loginResponse();
      if (url.endsWith('/file')) return fileResponse();
      assert.equal(url, FILE_URL);
      assert.deepEqual(options.headers, { Accept: 'application/epub+zip, application/octet-stream' });
      assert.equal(options.credentials, 'omit');
      cdnCalls++;
      return denied ? json({ success: 0, error: 'Please login', user: { remix_userkey: KEY } }, { status })
        : new Response(EPUB);
    } });
    const token = await login(app);
    await error(await app.post('download', { id: 42, hash: 'abc123' }, token, { Cookie: 'client=private' }), 502, 'INVALID_RESPONSE');
    assert.equal(calls, 3);
    assert.equal(cdnCalls, 1);
    denied = false;
    const response = await app.post('download', { id: 42, hash: 'abc123' }, token);
    assert.equal(response.status, 200);
    assert.deepEqual(Buffer.from(await response.arrayBuffer()), EPUB);
    assert.equal((await app.post('logout', {}, token)).status, 200);
    assert.equal(calls, 5);
    assert.equal(cdnCalls, 2);
  }
});

test('download denies explicit remote failure, denial and non EPUB files before fetching a link', async (t) => {
  for (const value of [
    { file: { extension: 'epub', downloadLink: FILE_URL } },
    { success: null, file: { extension: 'epub', downloadLink: FILE_URL } },
    { success: true, file: { extension: 'epub', downloadLink: FILE_URL } },
    { success: '1', file: { extension: 'epub', downloadLink: FILE_URL } },
    { success: 0, file: { extension: 'epub', downloadLink: FILE_URL } },
    { success: false, file: { extension: 'epub', downloadLink: FILE_URL } },
    { success: 1, allowDownload: false, file: { extension: 'epub', downloadLink: FILE_URL } },
    { success: 1, file: { extension: 'epub', downloadLink: FILE_URL, allowDownload: false } },
    { success: 1, file: { extension: 'pdf', downloadLink: FILE_URL } },
    { success: 1, file: { downloadLink: FILE_URL } }, { success: 1 },
  ]) {
    let calls = 0;
    const app = await start(t, { fetchImpl: async (url) => {
      calls++;
      return url.endsWith('/login') ? loginResponse() : json(value);
    } });
    const token = await login(app);
    await error(await app.post('download', { id: 42, hash: 'abc123' }, token), 403, 'DOWNLOAD_DENIED');
    assert.equal(calls, 2);
    assert.equal((await app.post('logout', {}, token)).status, 200);
  }
});

test('download accepts absent optional allowDownload only with success exactly 1 and valid EPUB metadata', async (t) => {
  const app = await start(t, { fetchImpl: async (url) => {
    if (url.endsWith('/login')) return loginResponse();
    if (url.endsWith('/file')) return json({ success: 1, file: { extension: 'EPUB', downloadLink: FILE_URL } });
    return new Response(EPUB);
  } });
  const token = await login(app);
  const response = await app.post('download', { id: 42, hash: 'abc123' }, token);
  assert.equal(response.status, 200);
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), EPUB);
});

test('root-relative API links download through the approved CDN without leaking the session', async (t) => {
  const link = '/dl/fixture?signature=private-signed-fixture';
  const destination = 'https://dln1.ncdn.ec/books/fixture.epub?signature=private-signed-fixture';
  const calls = [];
  const app = await start(t, { integration: true, fetchImpl: async (url, options) => {
    calls.push(url);
    if (url.endsWith('/login')) return loginResponse();
    if (url.endsWith('/file')) return fileResponse({ file: { extension: 'epub', downloadLink: link } });
    if (url === `https://z-library.biz${link}`) {
      assert.equal(options.headers.Cookie, `remix_userid=${USER_ID}; remix_userkey=${KEY}; siteLanguageV2=en`);
      return new Response(null, { status: 302, headers: { Location: destination } });
    }
    assert.equal(url, destination);
    assert.deepEqual(options.headers, { Accept: 'application/epub+zip, application/octet-stream' });
    assert.equal(options.credentials, 'omit');
    assert.equal(options.redirect, 'manual');
    return new Response(EPUB);
  } });
  const token = await login(app);
  const response = await app.post('download', { id: 42, hash: 'abc123' }, token, { Cookie: 'client=private' });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('content-type'), 'application/epub+zip');
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), EPUB);
  assert.equal(calls.length, 4);
  assert.equal((await app.post('logout', {}, token)).status, 200);
  assert.throws(() => validateUpstream(destination));
});

test('approved CDN links work directly and validate relative redirects without cookies', async (t) => {
  let hops = 0;
  const app = await start(t, { fetchImpl: async (url, options) => {
    if (url.endsWith('/login')) return loginResponse();
    if (url.endsWith('/file')) return fileResponse({ file: { extension: 'epub', downloadLink: 'https://dln1.ncdn.ec/start' } });
    assert.deepEqual(options.headers, { Accept: 'application/epub+zip, application/octet-stream' });
    assert.equal(url, `https://dln1.ncdn.ec/${hops++ === 0 ? 'start' : 'book.epub'}`);
    return hops === 1 ? new Response(null, { status: 307, headers: { Location: '/book.epub' } }) : new Response(EPUB);
  } });
  const token = await login(app);
  const response = await app.post('download', { id: 42, hash: 'abc123' }, token);
  assert.equal(response.status, 200);
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), EPUB);
  assert.equal(hops, 2);
});

test('file URLs reject SSRF, unknown hosts, userinfo, controls, backslashes, fragments and unsafe ports', async (t) => {
  for (const downloadLink of [
    'http://cdn-zlib.sk/book', 'https://127.0.0.1/book', 'https://2130706433/book', 'https://[::1]/book',
    'https://localhost/book', 'https://evil.example/book', 'https://cdn-zlib.sk.evil.example/book',
    'https://evilcdn-zlib.sk/book', 'https://sub.z-library.biz/book', 'https://cdn-zlib.sk./book',
    'https://user:pass@cdn-zlib.sk/book', 'https://@cdn-zlib.sk/book', 'https:////@cdn-zlib.sk/book',
    'https://cdn-zlib.sk:444/book',
    'https://cdn-zlib.sk\\@localhost/book', 'https://cdn-zlib.sk/\nbook',
    'https://cdn-zlib.sk/\tbook', 'https://cdn-zlib.sk/book#fragment', 'https:cdn-zlib.sk/book',
    'https://ncdn.ec/book', 'https://dln2.ncdn.ec/book', 'https://sub.dln1.ncdn.ec/book',
    'https://dln1.ncdn.ec.evil.example/book', 'https://evildln1.ncdn.ec/book',
    'http://dln1.ncdn.ec/book', 'https://dln1.ncdn.ec:444/book', 'https://@dln1.ncdn.ec/book',
    '//dln1.ncdn.ec/book', '//evil.example/book', '/\\evil.example/book', '/dl/fixture#fragment',
    'dl/fixture', '?signature=private', '', null,
  ]) {
    let calls = 0;
    const app = await start(t, { fetchImpl: async (url) => {
      calls++;
      return url.endsWith('/login') ? loginResponse() : fileResponse({ file: { extension: 'epub', downloadLink } });
    } });
    const token = await login(app);
    await error(await app.post('download', { id: 42, hash: 'abc123' }, token), 502, 'HOST_NOT_ALLOWED');
    assert.equal(calls, 2, String(downloadLink));
  }
});

test('file redirects validate every hop and send cookies only to exact API host', async (t) => {
  const urls = [
    'https://z-library.biz/book.epub', 'https://cdn-zlib.sk/one',
    'https://a.b.cdn-zlib.sk/two', 'https://z-library.biz:443/last',
  ];
  const canonical = urls.map((url) => new URL(url).href);
  let hop = 0;
  const redirects = [];
  const app = await start(t, { fetchImpl: async (url, options) => {
    if (url.endsWith('/login')) return loginResponse();
    if (url.endsWith('/file')) return fileResponse({ file: { extension: 'epub', downloadLink: urls[0] } });
    assert.equal(url, canonical[hop]);
    assert.equal(options.headers.Authorization, undefined);
    assert.equal(options.headers.Cookie, new URL(url).hostname === 'z-library.biz'
      ? `remix_userid=${USER_ID}; remix_userkey=${KEY}; siteLanguageV2=en` : undefined);
    if (hop++ < 3) {
      const redirect = tracked(302, { Location: urls[hop] });
      redirects.push(redirect);
      return redirect.response;
    }
    return new Response(EPUB);
  } });
  const token = await login(app);
  assert.equal((await app.post('download', { id: 42, hash: 'abc123' }, token, { Cookie: 'injected=secret' })).status, 200);
  assert.equal(hop, 4);
  assert.ok(redirects.every((item) => item.cancelled));
});

test('relative redirects stay public on CDN; hostile later hops and redirect loops fail closed', async (t) => {
  for (const location of ['https://evil.example/private', 'http://cdn-zlib.sk/private',
    'https://dln2.ncdn.ec/private', 'https://sub.dln1.ncdn.ec/private', 'https://dln1.ncdn.ec.evil.example/private',
    'https://127.0.0.1/', 'https://@cdn-zlib.sk/private', '///@cdn-zlib.sk/private', 'https://cdn-zlib.sk\\@localhost/',
    'https://cdn-zlib.sk:80/', '/loop', null]) {
    let hops = 0;
    const redirects = [];
    const app = await start(t, { fetchImpl: async (url, options) => {
      if (url.endsWith('/login')) return loginResponse();
      if (url.endsWith('/file')) return fileResponse();
      assert.equal(options.headers.Cookie, undefined);
      const redirect = tracked(307, hops++ === 0 ? { Location: '/relative' } : (location ? { Location: location } : {}));
      redirects.push(redirect);
      return redirect.response;
    } });
    const token = await login(app);
    await error(await app.post('download', { id: 42, hash: 'abc123' }, token), 502,
      location === '/loop' ? 'INVALID_RESPONSE' : 'HOST_NOT_ALLOWED');
    assert.equal(hops, location === '/loop' ? 4 : 2);
    assert.ok(redirects.every((item) => item.cancelled));
  }
});

test('login and API redirects are never followed, HTML/anti-bot and network errors are safe without retry', async (t) => {
  for (const operation of ['search', 'login', 'download']) {
    for (const kind of ['redirect', 'html', 'bad-json', 'array', 'network', 'http-error', 'html-as-json']) {
      let calls = 0;
      let upstream;
      const app = await start(t, { fetchImpl: async (url) => {
        if (operation === 'download' && url.endsWith('/login')) return loginResponse();
        calls++;
        if (kind === 'network') throw new Error(`${EMAIL} ${PASSWORD} ${KEY} ${FILE_URL}`);
        if (kind === 'redirect') { upstream = tracked(302, { Location: FILE_URL }); return upstream.response; }
        if (kind === 'html') { upstream = tracked(200, { 'Content-Type': 'text/html' }); return upstream.response; }
        if (kind === 'http-error') { upstream = tracked(503, { 'Content-Type': 'text/html' }); return upstream.response; }
        if (kind === 'array') return json([]);
        return new Response(kind === 'bad-json' ? '{' : `<html>${KEY}</html>`, { headers: { 'Content-Type': 'application/json' } });
      } });
      const token = operation === 'download' ? await login(app) : undefined;
      const body = operation === 'search' ? { query: '', page: 1 } : operation === 'login'
        ? { email: EMAIL, password: PASSWORD } : { id: 42, hash: 'abc123' };
      await error(await app.post(operation, body, token), 502,
        ['redirect', 'network', 'http-error'].includes(kind) ? 'UPSTREAM_UNAVAILABLE' : 'INVALID_RESPONSE');
      assert.equal(calls, 1, `${operation}: ${kind}`);
      if (upstream) assert.equal(upstream.cancelled, true);
    }
  }
});

test('remote JSON is limited to 4 MiB with declared, absent and misleading lengths', async (t) => {
  for (const kind of ['declared', 'streamed', 'compressed']) {
    let upstream;
    const app = await start(t, { fetchImpl: async () => {
      if (kind === 'declared') {
        upstream = tracked(200, { 'Content-Type': 'application/json', 'Content-Length': String(4 * MiB + 1) });
        return upstream.response;
      }
      let sent = 0;
      upstream = { cancelled: false };
      return new Response(new ReadableStream({
        pull(controller) { sent += MiB; controller.enqueue(Buffer.alloc(MiB, 32)); },
        cancel() { upstream.cancelled = true; },
      }), { headers: { 'Content-Type': 'application/json', ...(kind === 'compressed' ? { 'Content-Length': '1', 'Content-Encoding': 'gzip' } : {}) } });
    } });
    await error(await app.post('search', { query: '', page: 1 }), 413, 'TOO_LARGE');
    assert.equal(upstream.cancelled, true);
  }
  const value = JSON.stringify({ success: 1, books: [] });
  const app = await start(t, { fetchImpl: async () => new Response(value + ' '.repeat(4 * MiB - value.length), {
    headers: { 'Content-Type': 'application/json', 'Content-Length': String(4 * MiB) },
  }) });
  assert.equal((await app.post('search', { query: '', page: 1 })).status, 200);
});

test('download bytes are bounded to 40 MiB and ZIP local-file magic is mandatory', async (t) => {
  for (const kind of ['declared', 'streamed', 'compressed', 'html', 'corrupt', 'empty', 'fake-pk']) {
    let cancelled = false;
    const app = await start(t, { fetchImpl: async (url) => {
      if (url.endsWith('/login')) return loginResponse();
      if (url.endsWith('/file')) return fileResponse();
      if (kind === 'declared') {
        return new Response(new ReadableStream({ cancel() { cancelled = true; } }), { headers: { 'Content-Length': String(40 * MiB + 1) } });
      }
      if (kind === 'streamed' || kind === 'compressed') {
        return new Response(new ReadableStream({
          pull(controller) { controller.enqueue(Buffer.alloc(MiB)); }, cancel() { cancelled = true; },
        }), { headers: kind === 'compressed' ? { 'Content-Length': '1', 'Content-Encoding': 'gzip' } : {} });
      }
      return new Response({ html: `<html>${KEY}</html>`, corrupt: 'not a zip', empty: '', 'fake-pk': 'PKxx' }[kind]);
    } });
    const token = await login(app);
    const oversized = ['declared', 'streamed', 'compressed'].includes(kind);
    await error(await app.post('download', { id: 42, hash: 'abc123' }, token), oversized ? 413 : 502,
      oversized ? 'TOO_LARGE' : 'INVALID_RESPONSE');
    if (oversized) assert.equal(cancelled, true);
  }
  const bytes = Buffer.alloc(40 * MiB);
  EPUB.copy(bytes);
  const app = await start(t, { fetchImpl: async (url) => url.endsWith('/login') ? loginResponse()
    : url.endsWith('/file') ? fileResponse() : new Response(bytes) });
  const token = await login(app);
  const response = await app.post('download', { id: 42, hash: 'abc123' }, token);
  assert.equal(response.status, 200);
  assert.equal((await response.arrayBuffer()).byteLength, 40 * MiB);
});

test('deadline handles fetch ignoring abort, late replies, stalled JSON/file streams and slow local body', async (t) => {
  for (const kind of ['fetch', 'late-login', 'json-body', 'file-body']) {
    const entered = deferred();
    const release = deferred();
    let signal;
    let upstream;
    const app = await start(t, { timeoutMs: 40, fetchImpl: async (url, options) => {
      if (kind === 'file-body' && url.endsWith('/login')) return loginResponse();
      if (kind === 'file-body' && url.endsWith('/file')) return fileResponse();
      signal = options.signal;
      entered.resolve();
      if (kind === 'fetch') { await release.promise; return json({ success: 1, books: [] }); }
      if (kind === 'late-login') { await release.promise; upstream = tracked(200); return upstream.response; }
      upstream = tracked(200, { 'Content-Type': 'application/json' }, kind === 'file-body' ? EPUB : undefined);
      return upstream.response;
    } });
    const token = kind === 'file-body' ? await login(app) : undefined;
    const operation = kind === 'late-login' ? 'login' : kind === 'file-body' ? 'download' : 'search';
    const body = operation === 'login' ? { email: EMAIL, password: PASSWORD }
      : operation === 'download' ? { id: 42, hash: 'abc123' } : { query: '', page: 1 };
    const result = app.post(operation, body, token);
    await entered.promise;
    await error(await result, 504, 'TIMEOUT');
    assert.equal(signal.aborted, true);
    release.resolve();
    await new Promise((accept) => setImmediate(accept));
    if (upstream) assert.equal(upstream.cancelled, true);
  }
  const app = await start(t, { timeoutMs: 40 });
  const result = await new Promise((resolve, reject) => {
    const request = http.request(`${app.base}${PREFIX}search`, { method: 'POST', headers: {
      'Content-Type': 'application/json', 'X-Leitura-Client': '1', 'Transfer-Encoding': 'chunked',
    } }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => { request.end(); resolve({ status: response.statusCode, body: Buffer.concat(chunks).toString() }); });
    });
    request.on('error', reject);
    request.write('{');
  });
  assert.equal(result.status, 504);
  assert.equal(JSON.parse(result.body).code, 'TIMEOUT');
});

test('total deadline spans metadata and file fetches rather than resetting per fetch', async (t) => {
  let signal;
  let calls = 0;
  let lateFile;
  const app = await start(t, { timeoutMs: 300, fetchImpl: async (url, options) => {
    if (url.endsWith('/login')) return loginResponse();
    calls++;
    await new Promise((accept) => setTimeout(accept, 180));
    if (url.endsWith('/file')) return fileResponse();
    signal = options.signal;
    lateFile = { cancelled: false };
    lateFile.response = new Response(new ReadableStream({
      start(controller) { controller.enqueue(EPUB); },
      pull(controller) { controller.close(); },
      cancel() { lateFile.cancelled = true; },
    }));
    return lateFile.response;
  } });
  const token = await login(app);
  await error(await app.post('download', { id: 42, hash: 'abc123' }, token), 504, 'TIMEOUT');
  await new Promise((accept) => setTimeout(accept, 100));
  assert.equal(signal.aborted, true);
  assert.equal(lateFile.cancelled, true);
  assert.equal(calls, 2);
});

test('client disconnect aborts fetch even when it ignores abort and cancels a late body', async (t) => {
  const entered = deferred();
  const release = deferred();
  let signal;
  let upstream;
  const app = await start(t, { fetchImpl: async (_url, options) => {
    signal = options.signal;
    entered.resolve();
    await release.promise;
    upstream = tracked(200, { 'Content-Type': 'application/json' });
    return upstream.response;
  } });
  const request = http.request(`${app.base}${PREFIX}search`, { method: 'POST', headers: {
    'Content-Type': 'application/json', 'X-Leitura-Client': '1',
  } });
  request.on('error', () => {});
  request.end('{"query":"","page":1}');
  await entered.promise;
  request.destroy();
  for (let index = 0; index < 20 && !signal.aborted; index++) await new Promise((accept) => setTimeout(accept, 5));
  assert.equal(signal.aborted, true);
  release.resolve();
  await new Promise((accept) => setImmediate(accept));
  assert.equal(upstream.cancelled, true);
});

test('logout during download never restores session or delivers pending file bytes', async (t) => {
  for (const stage of ['metadata', 'file']) {
    const entered = deferred();
    const release = deferred();
    let calls = 0;
    const app = await start(t, { fetchImpl: async (url) => {
      calls++;
      if (url.endsWith('/login')) return loginResponse();
      if (url.endsWith('/file')) {
        if (stage === 'metadata') { entered.resolve(); await release.promise; }
        return fileResponse();
      }
      entered.resolve();
      await release.promise;
      return new Response(EPUB);
    } });
    const token = await login(app);
    const pending = app.post('download', { id: 42, hash: 'abc123' }, token);
    await entered.promise;
    assert.equal((await app.post('logout', {}, token)).status, 200);
    release.resolve();
    await error(await pending, 401, 'AUTH_REQUIRED');
    await error(await app.post('download', { id: 42, hash: 'abc123' }, token), 401, 'AUTH_REQUIRED');
    assert.equal(calls, stage === 'metadata' ? 2 : 3);
  }
});

test('handler close clears sessions and prevents late login from recreating state', async (t) => {
  const entered = deferred();
  const release = deferred();
  let pending = false;
  let signal;
  const app = await start(t, { fetchImpl: async (_url, options) => {
    if (pending) { signal = options.signal; entered.resolve(); await release.promise; }
    return loginResponse();
  } });
  await login(app);
  pending = true;
  const result = app.post('login', { email: EMAIL, password: PASSWORD });
  await entered.promise;
  app.handler.close();
  await error(await result, 502, 'UPSTREAM_UNAVAILABLE');
  assert.equal(signal.aborted, true);
  release.resolve();
  await new Promise((accept) => setImmediate(accept));
  await error(await app.post('search', { query: '', page: 1 }), 502, 'UPSTREAM_UNAVAILABLE');
});

test('factory validates dependency options', () => {
  for (const options of [{ timeoutMs: 0 }, { timeoutMs: NaN }, { fetchImpl: null }, { now: 0 },
    { sessionStore: null }, { sessionStore: {} }]) {
    assert.throws(() => createZlibraryHandler(options));
  }
});

async function persistentStore(t) {
  const directory = await mkdtemp(join(tmpdir(), 'leitura-zlibrary-handler-'));
  const stores = [];
  t.after(async () => {
    for (const store of stores) store.close();
    await rm(directory, { recursive: true, force: true });
  });
  return { directory, get current() { return stores.at(-1); }, store: () => {
    const store = createZlibrarySessionStore(directory);
    stores.push(store);
    return store;
  } };
}

test('handler close holds the writer through late work after timeout, disconnect or shutdown', async (t) => {
  for (const reason of ['timeout', 'disconnect', 'shutdown']) {
    const disk = await persistentStore(t);
    const entered = deferred();
    const release = deferred();
    let pending = false;
    const app = await start(t, { timeoutMs: reason === 'timeout' ? 40 : 5000,
      sessionStore: disk.store(), fetchImpl: async () => {
        if (pending) { entered.resolve(); await release.promise; }
        return loginResponse();
      } });
    const token = await login(app);
    pending = true;
    let request;
    const result = reason === 'disconnect' ? undefined : app.post('login', { email: EMAIL, password: PASSWORD });
    if (reason === 'disconnect') {
      request = http.request(`${app.base}${PREFIX}login`, { method: 'POST', headers: {
        'Content-Type': 'application/json', 'X-Leitura-Client': '1',
      } });
      request.on('error', () => {});
      request.end(JSON.stringify({ email: EMAIL, password: PASSWORD }));
    }
    await entered.promise;
    if (reason === 'timeout') await error(await result, 504, 'TIMEOUT');
    if (request) request.destroy();
    const closing = app.handler.close();
    assert.equal(app.handler.close(), closing, 'Concurrent close calls share completion.');
    let finished = false;
    closing.then(() => { finished = true; });
    if (reason === 'shutdown') await error(await result, 502, 'UPSTREAM_UNAVAILABLE');
    await new Promise((accept) => setImmediate(accept));
    assert.equal(finished, false);
    assert.throws(() => disk.store(), /session storage unavailable/);
    assert.deepEqual(disk.current.load().map((item) => item.token), [token]);
    release.resolve();
    await closing;
    const restarted = await start(t, { sessionStore: disk.store() });
    assert.equal((await restarted.post('session', {}, undefined, {
      Cookie: `leitura_zlibrary_session=${token}`,
    })).status, 200);
    assert.equal(disk.current.load().length, 1, 'Late login cannot persist a new session.');
  }
});

test('two handlers cannot take snapshots from the same store instance', async (t) => {
  const disk = await persistentStore(t);
  const store = disk.store();
  const handler = createZlibraryHandler({ sessionStore: store });
  assert.throws(() => createZlibraryHandler({ sessionStore: store }), /session storage unavailable/);
  await handler.close();
  const restarted = createZlibraryHandler({ sessionStore: disk.store() });
  await restarted.close();
});

test('handler keeps its writer until asynchronous upstream body cancellation settles', async (t) => {
  const disk = await persistentStore(t);
  const release = deferred();
  const cancelled = deferred();
  const app = await start(t, { sessionStore: disk.store(), fetchImpl: async () => new Response(
    new ReadableStream({ cancel() { cancelled.resolve(); return release.promise; } }), { status: 503 },
  ) });
  await error(await app.post('search', { query: '', page: 1 }), 502, 'UPSTREAM_UNAVAILABLE');
  await cancelled.promise;
  const closing = app.handler.close();
  let finished = false;
  closing.then(() => { finished = true; });
  await new Promise((accept) => setImmediate(accept));
  assert.equal(finished, false);
  assert.throws(() => disk.store(), /session storage unavailable/);
  release.resolve();
  await closing;
  const restarted = disk.store();
  restarted.close();
});

test('remembered session survives close/restart and slides 30 days while access remains 30 minutes', async (t) => {
  const disk = await persistentStore(t);
  let clock = 1000;
  const first = await start(t, { now: () => clock, sessionStore: disk.store(), fetchImpl: async () => loginResponse() });
  const token = await login(first);
  const cookie = { Cookie: `leitura_zlibrary_session=${token}` };
  await first.handler.close();
  clock += 29 * DAY;
  let calls = 0;
  const second = await start(t, { now: () => clock, sessionStore: disk.store(), fetchImpl: async (url) => {
    calls++;
    return url.endsWith('/file') ? fileResponse() : new Response(EPUB);
  } });
  await error(await second.post('download', { id: 42, hash: 'abc123' }, token), 401, 'AUTH_REQUIRED');
  const restored = await second.post('session', {}, undefined, cookie);
  assert.equal(restored.status, 200);
  assert.deepEqual(await restored.json(), { session: token, expiresIn: 1800 });
  assert.match(restored.headers.get('set-cookie'), /Max-Age=2592000/);
  assert.equal(calls, 0, 'Renewal does not validate or refresh the remote key upstream.');
  assert.equal((await second.post('download', { id: 42, hash: 'abc123' }, token)).status, 200);
  clock += 30 * 60_000;
  await error(await second.post('download', { id: 42, hash: 'abc123' }, token), 401, 'AUTH_REQUIRED');
  await second.handler.close();
  clock = 1000 + 58 * DAY;
  const third = await start(t, { now: () => clock, sessionStore: disk.store() });
  assert.equal((await third.post('session', {}, undefined, cookie)).status, 200);
  const saved = disk.current.load();
  assert.equal(saved[0].rememberedUntil, clock + 30 * DAY);
  for (const name of await readdir(disk.directory)) {
    if (name === 'writer.lock') continue;
    const bytes = await readFile(join(disk.directory, name));
    for (const value of [token, KEY, EMAIL, PASSWORD, String(USER_ID)]) {
      assert.equal(bytes.includes(Buffer.from(value)), false);
    }
  }
  clock += 30 * DAY;
  await error(await third.post('session', {}, undefined, cookie), 401, 'AUTH_REQUIRED');
  assert.deepEqual(disk.current.load(), []);
});

test('expired bearer can log out but cannot download, and logout stays revoked across restart', async (t) => {
  const disk = await persistentStore(t);
  let clock = 1000;
  const first = await start(t, { now: () => clock, sessionStore: disk.store(), fetchImpl: async () => loginResponse() });
  const token = await login(first);
  clock += 31 * 60_000;
  await error(await first.post('download', { id: 42, hash: 'abc123' }, token), 401, 'AUTH_REQUIRED');
  await error(await first.post('logout', {}, 'a'.repeat(43)), 401, 'AUTH_REQUIRED');
  await error(await first.post('logout', {}, undefined, { Cookie: `leitura_zlibrary_session=${token}` }), 401, 'AUTH_REQUIRED');
  const logout = await first.post('logout', {}, token);
  assert.equal(logout.status, 200);
  assert.equal(logout.headers.get('set-cookie'), null);
  assert.deepEqual(disk.current.load(), []);
  await error(await first.post('session', {}, undefined, { Cookie: `leitura_zlibrary_session=${token}` }), 401, 'AUTH_REQUIRED');
  await first.handler.close();
  const second = await start(t, { sessionStore: disk.store(), now: () => clock });
  await error(await second.post('session', {}, undefined, { Cookie: `leitura_zlibrary_session=${token}` }), 401, 'AUTH_REQUIRED');
});

test('a record expiring exactly 30 days after login is denied and removed after restart', async (t) => {
  const disk = await persistentStore(t);
  let clock = 1000;
  const first = await start(t, { now: () => clock, sessionStore: disk.store(), fetchImpl: async () => loginResponse() });
  const token = await login(first);
  await first.handler.close();
  clock += 30 * DAY;
  const second = await start(t, { now: () => clock, sessionStore: disk.store() });
  await error(await second.post('session', {}, undefined, { Cookie: `leitura_zlibrary_session=${token}` }), 401, 'AUTH_REQUIRED');
  await error(await second.post('download', { id: 42, hash: 'abc123' }, token), 401, 'AUTH_REQUIRED');
  assert.deepEqual(disk.current.load(), []);
});

test('remote revocation is durable for metadata and authenticated download responses', async (t) => {
  for (const stage of ['metadata', 'file']) {
    for (const status of [200, 401]) {
      const disk = await persistentStore(t);
      const first = await start(t, { sessionStore: disk.store(), fetchImpl: async (url) => {
        if (url.endsWith('/login')) return loginResponse();
        if (stage === 'file' && url.endsWith('/file')) {
          return json({ success: 1, file: { extension: 'epub', downloadLink: '/file-fixture' } });
        }
        return status === 401 ? new Response('{malformed', { status }) : json({ message: 'Please login' });
      } });
      const token = await login(first);
      const other = await login(first);
      await error(await first.post('download', { id: 42, hash: 'abc123' }, token), 401, 'AUTH_REQUIRED');
      assert.throws(() => disk.store(), /session storage unavailable/);
      await first.handler.close();
      const second = await start(t, { sessionStore: disk.store() });
      await error(await second.post('session', {}, undefined, { Cookie: `leitura_zlibrary_session=${token}` }), 401, 'AUTH_REQUIRED');
      assert.equal((await second.post('session', {}, undefined, { Cookie: `leitura_zlibrary_session=${other}` })).status, 200);
    }
  }
});

test('remembered records count toward the 32-session cap across restarts until logout or remembered expiry', async (t) => {
  const disk = await persistentStore(t);
  let clock = 0;
  const first = await start(t, { sessionStore: disk.store(), now: () => clock, fetchImpl: async () => loginResponse() });
  const tokens = [];
  for (let index = 0; index < 32; index++) {
    clock += 60_000;
    tokens.push(await login(first));
  }
  await first.handler.close();
  clock += 31 * 60_000;
  let calls = 0;
  const second = await start(t, { sessionStore: disk.store(), now: () => clock, fetchImpl: async () => {
    calls++;
    return loginResponse();
  } });
  await error(await second.post('login', { email: EMAIL, password: PASSWORD }), 429, 'SESSION_LIMIT');
  assert.equal(calls, 0);
  assert.equal((await second.post('logout', {}, tokens[0])).status, 200);
  await login(second);
  clock += 30 * DAY;
  await login(second);
  assert.equal(disk.current.load().length, 1);
});

test('persistence failure never reports successful login, renewal, logout or upstream revocation', async (t) => {
  for (const operation of ['login', 'session', 'logout', 'download']) {
    const disk = await persistentStore(t);
    const store = disk.store();
    let broken = false;
    const app = await start(t, { sessionStore: {
      load: () => store.load(),
      close: () => store.close(),
      save: (records) => {
        if (broken) throw new Error(`${KEY} ${PASSWORD} ${EMAIL}`);
        store.save(records);
      },
    }, fetchImpl: async (url) => url.endsWith('/login') ? loginResponse() : json({ message: 'Please login' }) });
    const token = await login(app);
    const original = store.load();
    broken = true;
    const body = operation === 'login' ? { email: EMAIL, password: PASSWORD }
      : operation === 'download' ? { id: 42, hash: 'abc123' } : {};
    await error(await app.post(operation, body, token, { Cookie: `leitura_zlibrary_session=${token}` }), 502, 'UPSTREAM_UNAVAILABLE');
    assert.deepEqual(store.load(), original, 'Failed save does not commit an in-memory-only transition.');
    await error(await app.post('session', {}, undefined, { Cookie: `leitura_zlibrary_session=${token}` }), 502, 'UPSTREAM_UNAVAILABLE');
  }
});

test('runtime tampering or insecure state permissions cannot produce successful renewal or overwrite state', async (t) => {
  for (const insecure of [false, true]) {
    const disk = await persistentStore(t);
    const app = await start(t, { sessionStore: disk.store(), fetchImpl: async () => loginResponse() });
    const token = await login(app);
    const statePath = join(disk.directory, 'sessions');
    if (insecure) await chmod(statePath, 0o644);
    else await writeFile(statePath, 'corrupt-fixture-state');
    const before = await readFile(statePath);
    await error(await app.post('session', {}, undefined, { Cookie: `leitura_zlibrary_session=${token}` }), 502, 'UPSTREAM_UNAVAILABLE');
    assert.deepEqual(await readFile(statePath), before);
  }
});

test('session renewal waiting on a body cannot overwrite a concurrent logout or newer login cookie', async (t) => {
  for (const logout of [false, true]) {
    const disk = await persistentStore(t);
    const app = await start(t, { sessionStore: disk.store(), fetchImpl: async () => loginResponse() });
    const token = await login(app);
    const pending = deferred();
    const received = once(app.server, 'request');
    const request = http.request(`${app.base}${PREFIX}session`, { method: 'POST', headers: {
      'Content-Type': 'application/json', 'X-Leitura-Client': '1', Cookie: `leitura_zlibrary_session=${token}`,
    } }, (response) => {
      response.resume();
      response.once('end', () => pending.resolve(response));
    });
    request.flushHeaders();
    request.write('{');
    await received;
    if (logout) assert.equal((await app.post('logout', {}, token)).status, 200);
    const newer = await login(app);
    request.end('}');
    const response = await pending.promise;
    assert.equal(response.statusCode, 401);
    assert.equal(response.headers['set-cookie'], undefined);
    const restored = await app.post('session', {}, undefined, { Cookie: `leitura_zlibrary_session=${newer}` });
    assert.equal(restored.status, 200);
    if (logout) assert.equal(disk.current.load().some((item) => item.token === token), false);
  }
});
