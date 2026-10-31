import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, mkdir, rm, symlink, writeFile } from 'node:fs/promises';
import http from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { createServer, validateUpstream } from './serve.mjs';
import { createZlibrarySessionStore } from './zlibrary_session_store.mjs';

const run = promisify(execFile);
const script = fileURLToPath(new URL('./serve.mjs', import.meta.url));
const MiB = 1024 * 1024;
let temporary;
let root;

before(async () => {
  temporary = await mkdtemp(join(tmpdir(), 'leitura-serve-'));
  root = join(temporary, 'web');
  await mkdir(root);
  await mkdir(join(root, 'assets'));
  await writeFile(join(root, 'index.html'), '<html>Flutter fixture</html>');
  for (const name of ['main.dart.js', 'flutter_service_worker.js', 'app.wasm', 'font.ttf', 'icon.png', 'favicon.ico', 'icon.svg', 'manifest.json']) {
    await writeFile(join(root, name), `fixture: ${name}`);
  }
  await writeFile(join(temporary, 'secret.txt'), 'not public');
  await mkdir(join(temporary, 'web-outside'));
  await writeFile(join(temporary, 'web-outside', 'secret.txt'), 'also not public');
  await symlink(join(temporary, 'secret.txt'), join(root, 'escape.txt'));
  await symlink(join(temporary, 'web-outside'), join(root, 'escape'));
  await symlink(join(root, 'main.dart.js'), join(root, 'safe.js'));
});

after(async () => {
  await rm(temporary, { recursive: true, force: true });
});

async function start(t, options = {}) {
  const server = await createServer({
    staticRoot: root,
    fetchImpl: () => { throw new Error('Unexpected upstream request.'); },
    ...options,
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(async () => {
    server.closeAllConnections();
    await new Promise((accept) => server.close(accept));
  });
  return `http://127.0.0.1:${server.address().port}`;
}

function proxy(base, url = 'https://gutendex.com/books/') {
  return `${base}/api/proxy?url=${encodeURIComponent(url)}`;
}

function rawRequest(base, path, method = 'GET') {
  return new Promise((accept, reject) => {
    const request = http.request(`${base}/`, { path, method }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('error', reject);
      response.on('end', () => accept({
        status: response.statusCode,
        headers: response.headers,
        body: Buffer.concat(chunks).toString(),
      }));
    });
    request.on('error', reject);
    request.end();
  });
}

function trackedResponse(status, headers = {}) {
  const state = { cancelled: false };
  state.response = new Response(new ReadableStream({
    cancel() { state.cancelled = true; },
  }), { status, headers });
  return state;
}

test('validateUpstream accepts only the exact HTTPS hosts and port 443', () => {
  for (const host of ['gutendex.com', 'www.gutenberg.org', 'gutenberg.org']) {
    const url = validateUpstream(`https://${host}:443/books/?search=a%20b`);
    assert.equal(url.hostname, host);
    assert.equal(url.port, '');
    assert.equal(url.search, '?search=a%20b');
  }
  assert.equal(validateUpstream('https://GUTENDEX.COM/').hostname, 'gutendex.com');
});

for (const value of [
  'http://gutendex.com/',
  'ftp://gutendex.com/',
  'https://user:password@gutendex.com/',
  'https://user@gutendex.com/',
  'https://@gutendex.com/',
  'https://gutendex.com:444/',
  'https://gutendex.com:80/',
  'https://gutendex.com.evil.example/',
  'https://evilgutendex.com/',
  'https://sub.gutendex.com/',
  'https://gutendex.com./',
  'https://localhost/',
  'https://127.0.0.1/',
  'https://2130706433/',
  'https://[::1]/',
  'https://gutendex.com@localhost/',
  'https://gutendex.com\\@localhost/',
  '/books/',
  'not a URL',
]) {
  test(`validateUpstream rejects ${value}`, () => {
    assert.throws(() => validateUpstream(value), { status: 400 });
  });
}

test('import does not listen; createServer checks index.html without writing files', async () => {
  await assert.rejects(createServer({ staticRoot: join(temporary, 'missing') }), /Flutter build index.html.*flutter build web/);
  await assert.rejects(createServer({ staticRoot: join(root, 'assets') }), /index.html/);
  await assert.rejects(createServer({ staticRoot: root, timeoutMs: 0 }), /timeoutMs/);
  const server = await createServer({ staticRoot: root });
  assert.equal(server.listening, false);
});

test('server close callback waits for late Z-Library work and releases its persistent writer', async (t) => {
  const directory = join(temporary, 'server-session-store');
  const store = createZlibrarySessionStore(directory);
  let entered;
  let release;
  const fetching = new Promise((accept) => { entered = accept; });
  const pending = new Promise((accept) => { release = accept; });
  const server = await createServer({ staticRoot: root, sessionStore: store, fetchImpl: async () => {
    entered();
    await pending;
    return new Response(JSON.stringify({ success: 1, user: { id: 735192, remix_userkey: 'fixture_key' } }), {
      headers: { 'Content-Type': 'application/json' },
    });
  } });
  t.after(async () => {
    release();
    server.closeAllConnections();
    await new Promise((accept) => server.close(accept));
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const result = fetch(`http://127.0.0.1:${server.address().port}/api/zlibrary/login`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Leitura-Client': '1' },
    body: JSON.stringify({ email: 'fixture@example.invalid', password: 'fixture-password-not-real' }),
  });
  await fetching;
  let finished = false;
  const closing = new Promise((accept, reject) => {
    assert.equal(server.close((error) => {
      finished = true;
      if (error) reject(error);
      else accept();
    }), server);
  });
  const response = await result;
  assert.equal(response.status, 502);
  await response.text();
  await new Promise((accept) => setImmediate(accept));
  assert.equal(finished, false);
  assert.throws(() => createZlibrarySessionStore(directory), /session storage unavailable/);
  release();
  await closing;
  const restarted = createZlibrarySessionStore(directory);
  assert.deepEqual(restarted.load(), [], 'Aborted late login does not survive shutdown.');
  restarted.close();
});

test('static GET, HEAD, service worker, Flutter MIME types and cache headers', async (t) => {
  const base = await start(t);
  for (const [path, type] of [
    ['/', 'text/html; charset=utf-8'],
    ['/main.dart.js', 'text/javascript; charset=utf-8'],
    ['/flutter_service_worker.js', 'text/javascript; charset=utf-8'],
    ['/app.wasm', 'application/wasm'],
    ['/font.ttf', 'font/ttf'],
    ['/icon.png', 'image/png'],
    ['/favicon.ico', 'image/x-icon'],
    ['/icon.svg', 'image/svg+xml'],
    ['/manifest.json', 'application/json; charset=utf-8'],
  ]) {
    const response = await fetch(`${base}${path}`);
    assert.equal(response.status, 200, path);
    assert.equal(response.headers.get('content-type'), type, path);
    assert.equal(response.headers.get('cache-control'), 'no-cache');
    const body = await response.arrayBuffer();
    assert.equal(Number(response.headers.get('content-length')), body.byteLength);
  }
  const head = await fetch(`${base}/`, { method: 'HEAD' });
  assert.equal(head.status, 200);
  assert.ok(Number(head.headers.get('content-length')) > 0);
  assert.equal(await head.text(), '');
});

test('SPA fallback only for extensionless paths; directories have no listing', async (t) => {
  const base = await start(t);
  const response = await fetch(`${base}/books/42?tab=read`);
  assert.equal(response.status, 200);
  assert.match(await response.text(), /Flutter fixture/);
  for (const path of ['/missing.js', '/missing.json', '/assets/', '/assets']) {
    const missing = await fetch(`${base}${path}`);
    assert.equal(missing.status, 404, path);
    await missing.text();
  }
});

test('static rejects traversal, malformed encodings and escaping symlinks', async (t) => {
  const base = await start(t);
  for (const path of ['/../secret.txt', '/%2e%2e/secret.txt', '/a/%2e%2e/secret.txt', '/%2e%2e%2fsecret.txt', '/escape.txt', '/escape/secret.txt']) {
    const response = await rawRequest(base, path);
    assert.equal(response.status, 403, path);
    assert.doesNotMatch(response.body, /not public/);
  }
  for (const path of ['/%ZZ', '/%00', '/%5c..%5csecret.txt', '//outside/file']) {
    assert.equal((await rawRequest(base, path)).status, 400, path);
  }
  const safe = await fetch(`${base}/safe.js`);
  assert.equal(safe.status, 200);
  assert.match(await safe.text(), /main.dart.js/);
});

test('method restrictions and URL query validation do not call fetch', async (t) => {
  const base = await start(t);
  for (const [path, method, allow] of [
    ['/', 'POST', 'GET, HEAD'],
    ['/', 'OPTIONS', 'GET, HEAD'],
    ['/api/proxy', 'POST', 'GET'],
    ['/api/proxy', 'HEAD', 'GET'],
  ]) {
    const response = await fetch(`${base}${path}`, { method });
    assert.equal(response.status, 405);
    assert.equal(response.headers.get('allow'), allow);
    await response.text();
  }
  for (const query of ['', '?url=', '?url=https%3A%2F%2Flocalhost%2F', '?url=a&url=b']) {
    const response = await fetch(`${base}/api/proxy${query}`);
    assert.equal(response.status, 400, query);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.ok((await response.json()).error);
  }
});

test('proxy streams success and never forwards credentials or unsafe headers', async (t) => {
  const base = await start(t, {
    fetchImpl: async (url, options) => {
      assert.equal(url, 'https://gutendex.com/books/');
      assert.equal(options.method, 'GET');
      assert.equal(options.redirect, 'manual');
      assert.equal(options.credentials, 'omit');
      assert.deepEqual(options.headers, { Accept: '*/*' });
      const parts = [Buffer.from('{"results":'), Buffer.from('[1,2]}')];
      return new Response(new ReadableStream({
        pull(controller) {
          if (parts.length) controller.enqueue(parts.shift());
          else controller.close();
        },
      }), {
        headers: {
          'Content-Type': 'Application/JSON; charset=utf-8',
          'Content-Encoding': 'gzip',
          'Content-Length': '7',
          'Set-Cookie': 'secret=value',
          'Cache-Control': 'public',
        },
      });
    },
  });
  const response = await fetch(proxy(base), {
    headers: { Cookie: 'session=private', Authorization: 'Bearer private', Range: 'bytes=0-1' },
  });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('content-type'), 'application/json');
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(response.headers.get('content-length'), null);
  assert.equal(response.headers.get('content-encoding'), null);
  assert.equal(response.headers.get('set-cookie'), null);
  assert.deepEqual(await response.json(), { results: [1, 2] });
});

test('proxy sanitizes Content-Type to the relevant allowlist', async (t) => {
  for (const [incoming, expected] of [
    ['application/epub+zip', 'application/epub+zip'],
    ['image/jpeg', 'image/jpeg'],
    ['image/png', 'image/png'],
    ['image/webp', 'image/webp'],
    ['application/octet-stream', 'application/octet-stream'],
    ['text/html; charset=utf-8', 'application/octet-stream'],
    ['image/svg+xml', 'application/octet-stream'],
  ]) {
    const base = await start(t, {
      fetchImpl: async () => new Response('data', { headers: { 'Content-Type': incoming } }),
    });
    const response = await fetch(proxy(base));
    assert.equal(response.headers.get('content-type'), expected);
    assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
    assert.equal(await response.text(), 'data');
  }
});

test('proxy follows at most three validated redirects and cancels their bodies', async (t) => {
  const redirects = [
    trackedResponse(301, { Location: '/next' }),
    trackedResponse(302, { Location: 'https://www.gutenberg.org/books/1' }),
    trackedResponse(307, { Location: 'https://gutenberg.org/cache/1.epub' }),
  ];
  const seen = [];
  const base = await start(t, {
    fetchImpl: async (url) => {
      seen.push(url);
      return redirects[seen.length - 1]?.response ?? new Response('epub');
    },
  });
  const response = await fetch(proxy(base));
  assert.equal(await response.text(), 'epub');
  assert.deepEqual(seen, [
    'https://gutendex.com/books/',
    'https://gutendex.com/next',
    'https://www.gutenberg.org/books/1',
    'https://gutenberg.org/cache/1.epub',
  ]);
  assert.ok(redirects.every((item) => item.cancelled));
});

for (const location of [
  'http://gutendex.com/books/',
  'https://localhost/',
  'https://127.0.0.1/',
  'https://gutendex.com.evil.example/',
  'https://user:password@gutendex.com/',
  'https://gutendex.com:8443/',
]) {
  test(`proxy blocks redirect to ${location}`, async (t) => {
    const redirect = trackedResponse(302, { Location: location });
    let calls = 0;
    const base = await start(t, {
      fetchImpl: async () => { calls++; return redirect.response; },
    });
    const response = await fetch(proxy(base));
    assert.equal(response.status, 502);
    assert.match((await response.json()).error, /redirect is not allowed/);
    assert.equal(calls, 1);
    assert.equal(redirect.cancelled, true);
  });
}

test('proxy validates later hops, not just the first redirect', async (t) => {
  const redirects = [
    trackedResponse(302, { Location: 'https://gutenberg.org/next' }),
    trackedResponse(302, { Location: 'http://gutenberg.org/private' }),
  ];
  let calls = 0;
  const base = await start(t, { fetchImpl: async () => redirects[calls++].response });
  const response = await fetch(proxy(base));
  assert.equal(response.status, 502);
  await response.text();
  assert.equal(calls, 2);
  assert.ok(redirects.every((item) => item.cancelled));
});

test('proxy stops redirect loops after four requests', async (t) => {
  const redirects = [];
  const base = await start(t, {
    fetchImpl: async () => {
      const redirect = trackedResponse(308, { Location: '/again' });
      redirects.push(redirect);
      return redirect.response;
    },
  });
  const response = await fetch(proxy(base));
  assert.equal(response.status, 502);
  assert.match((await response.json()).error, /redirect limit/);
  assert.equal(redirects.length, 4);
  assert.ok(redirects.every((item) => item.cancelled));
});

test('proxy rejects a redirect without Location and cancels its body', async (t) => {
  const redirect = trackedResponse(302);
  const base = await start(t, { fetchImpl: async () => redirect.response });
  const response = await fetch(proxy(base));
  assert.equal(response.status, 502);
  assert.match((await response.json()).error, /no location/);
  assert.equal(redirect.cancelled, true);
});

test('proxy hides upstream HTTP error bodies and network error details', async (t) => {
  const upstream = trackedResponse(403, { 'Set-Cookie': 'private=secret' });
  const base = await start(t, { fetchImpl: async () => upstream.response });
  const response = await fetch(proxy(base));
  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), { error: 'Upstream returned HTTP 403.' });
  assert.equal(response.headers.get('set-cookie'), null);
  assert.equal(upstream.cancelled, true);
  const failed = await start(t, { fetchImpl: async () => { throw new Error('sensitive network detail'); } });
  const failure = await fetch(proxy(failed));
  assert.equal(failure.status, 502);
  assert.deepEqual(await failure.json(), { error: 'Upstream request failed.' });
});

test('proxy rejects oversized Content-Length upfront with 413 and cancels body', async (t) => {
  for (const [url, limit] of [
    ['https://gutendex.com/books/', 4 * MiB],
    ['https://www.gutenberg.org/book.epub', 40 * MiB],
  ]) {
    const upstream = trackedResponse(200, { 'Content-Length': String(limit + 1) });
    const base = await start(t, { fetchImpl: async () => upstream.response });
    const response = await fetch(proxy(base, url));
    assert.equal(response.status, 413);
    assert.match((await response.json()).error, /byte limit/);
    assert.equal(upstream.cancelled, true);
  }
});

test('catalog limit remains 4 MiB when gutendex redirects to Gutenberg', async (t) => {
  const redirect = trackedResponse(302, { Location: 'https://gutenberg.org/catalog' });
  const oversized = trackedResponse(200, { 'Content-Length': String(4 * MiB + 1) });
  let calls = 0;
  const base = await start(t, {
    fetchImpl: async () => calls++ === 0 ? redirect.response : oversized.response,
  });
  const response = await fetch(proxy(base));
  assert.equal(response.status, 413);
  await response.text();
  assert.equal(redirect.cancelled, true);
  assert.equal(oversized.cancelled, true);
});

test('proxy permits exactly 4 MiB of catalog data', async (t) => {
  const base = await start(t, {
    fetchImpl: async () => new Response(Buffer.alloc(4 * MiB), {
      headers: { 'Content-Length': String(4 * MiB) },
    }),
  });
  const response = await fetch(proxy(base));
  assert.equal(response.status, 200);
  assert.equal((await response.arrayBuffer()).byteLength, 4 * MiB);
});

test('proxy destroys oversized streams, including decompressed and undeclared bodies', async (t) => {
  for (const [url, limit, headers] of [
    ['https://gutendex.com/books/', 4 * MiB, { 'Content-Encoding': 'gzip', 'Content-Length': '1' }],
    ['https://gutenberg.org/book.epub', 40 * MiB, {}],
  ]) {
    let cancelled = false;
    let sent = 0;
    const base = await start(t, {
      fetchImpl: async () => new Response(new ReadableStream({
        pull(controller) {
          if (sent < limit + MiB) {
            sent += MiB;
            controller.enqueue(Buffer.alloc(MiB));
          }
        },
        cancel() { cancelled = true; },
      }), { headers }),
    });
    await assert.rejects(async () => {
      const response = await fetch(proxy(base, url));
      await response.arrayBuffer();
    });
    assert.equal(cancelled, true);
    assert.ok(sent <= limit + MiB);
  }
});

test('proxy timeout returns 504 even if injected fetch ignores abort', async (t) => {
  let signal;
  const base = await start(t, {
    timeoutMs: 25,
    fetchImpl: (_url, options) => {
      signal = options.signal;
      return new Promise(() => {});
    },
  });
  const response = await fetch(proxy(base));
  assert.equal(response.status, 504);
  assert.match((await response.json()).error, /timed out/);
  assert.equal(signal.aborted, true);
});

test('timeout is total across redirects, not renewed for each hop', async (t) => {
  const redirects = [];
  const base = await start(t, {
    timeoutMs: 70,
    fetchImpl: async () => {
      await new Promise((accept) => setTimeout(accept, 40));
      const redirect = trackedResponse(302, { Location: '/next' });
      redirects.push(redirect);
      return redirect.response;
    },
  });
  const response = await fetch(proxy(base));
  assert.equal(response.status, 504);
  await response.text();
  await new Promise((accept) => setTimeout(accept, 60));
  assert.equal(redirects.length, 2);
  assert.ok(redirects.every((item) => item.cancelled));
});

test('timeout also cancels a stalled streaming response', async (t) => {
  let cancelled = false;
  const base = await start(t, {
    timeoutMs: 30,
    fetchImpl: async () => new Response(new ReadableStream({
      start(controller) { controller.enqueue(Buffer.from('partial')); },
      cancel() { cancelled = true; },
    })),
  });
  await assert.rejects(async () => {
    const response = await fetch(proxy(base));
    await response.text();
  });
  assert.equal(cancelled, true);
});

test('CLI rejects malformed, out-of-range, missing and repeated arguments', async () => {
  for (const args of [
    ['--port'], ['--port', '0'], ['--port', '65536'], ['--port', '-1'],
    ['--port', '1.5'], ['--port', '1e3'], ['--port', 'NaN'],
    ['--host', '0.0.0.0'], ['--port=8787'], ['8787'],
    ['--port', '8787', '--port', '8788'],
  ]) {
    await assert.rejects(run(process.execPath, [script, ...args]), (error) => {
      assert.equal(error.code, 1);
      assert.match(error.stderr, /Usage:|Port must/);
      return true;
    });
  }
});
