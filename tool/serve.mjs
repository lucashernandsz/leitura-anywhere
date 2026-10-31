import http from 'node:http';
import { open, realpath, stat } from 'node:fs/promises';
import { dirname, extname, isAbsolute, relative, resolve, sep } from 'node:path';
import { Readable, Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createZlibraryHandler } from './zlibrary.mjs';
import { createZlibrarySessionStore } from './zlibrary_session_store.mjs';

const DEFAULT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../build/web');
const HOSTS = new Set(['gutendex.com', 'www.gutenberg.org', 'gutenberg.org']);
const MAX_BYTES = 40 * 1024 * 1024;
const CATALOG_BYTES = 4 * 1024 * 1024;
const REDIRECTS = new Set([301, 302, 303, 307, 308]);
const PROXY_TYPES = new Set([
  'application/json', 'application/epub+zip', 'image/jpeg', 'image/png',
  'image/webp', 'application/octet-stream',
]);
const STATIC_TYPES = {
  '.wasm': 'application/wasm',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.svg': 'image/svg+xml',
};

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

export function validateUpstream(value) {
  if (typeof value !== 'string' || value.includes('\\')) {
    throw new HttpError(400, 'Invalid upstream URL.');
  }
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new HttpError(400, 'Invalid upstream URL.');
  }
  if (url.protocol !== 'https:' || !/^https:\/\//i.test(value)) {
    throw new HttpError(400, 'Upstream must use HTTPS.');
  }
  if (url.username || url.password || value.split('/')[2]?.includes('@')) {
    throw new HttpError(400, 'Upstream credentials are not allowed.');
  }
  if (url.port && url.port !== '443') {
    throw new HttpError(400, 'Only upstream port 443 is allowed.');
  }
  if (!HOSTS.has(url.hostname)) {
    throw new HttpError(400, 'Upstream hostname is not allowed.');
  }
  return url;
}

function sendError(response, error, head = false) {
  if (response.destroyed || response.writableEnded) return;
  if (response.headersSent) {
    response.destroy();
    return;
  }
  const status = error instanceof HttpError ? error.status : 500;
  const message = error instanceof HttpError ? error.message : 'Internal server error.';
  const body = JSON.stringify({ error: message });
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
  });
  response.end(head ? undefined : body);
}

function assertBounds(root, target) {
  const path = relative(root, target);
  if (path === '..' || path.startsWith(`..${sep}`) || isAbsolute(path)) {
    throw new HttpError(403, 'Static path is outside the build directory.');
  }
}

async function resolveFile(root, path) {
  assertBounds(root, path);
  const canonical = await realpath(path);
  assertBounds(root, canonical);
  return canonical;
}

async function serveStatic(request, response, root, rawPath) {
  let path;
  try {
    path = decodeURIComponent(rawPath);
  } catch {
    throw new HttpError(400, 'Invalid path encoding.');
  }
  if (path.includes('\0') || path.includes('\\')) {
    throw new HttpError(400, 'Invalid static path.');
  }
  if (path.split('/').includes('..')) {
    throw new HttpError(403, 'Static path traversal is not allowed.');
  }
  let file;
  try {
    file = await resolveFile(root, resolve(root, `.${path === '/' ? '/index.html' : path}`));
  } catch (error) {
    if (error.code !== 'ENOENT' && error.code !== 'ENOTDIR') throw error;
    if (extname(path)) throw new HttpError(404, 'Static file not found.');
    file = await resolveFile(root, resolve(root, 'index.html'));
  }
  const handle = await open(file, 'r');
  try {
    const info = await handle.stat();
    if (!info.isFile()) throw new HttpError(404, 'Static file not found.');
    response.writeHead(200, {
      'Content-Type': STATIC_TYPES[extname(file).toLowerCase()] ?? 'application/octet-stream',
      'Content-Length': info.size,
      'Cache-Control': 'no-cache',
      'X-Content-Type-Options': 'nosniff',
    });
    if (request.method === 'HEAD') {
      response.end();
    } else {
      await pipeline(handle.createReadStream({ autoClose: false }), response);
    }
  } finally {
    await handle.close();
  }
}

async function serveProxy(request, response, query, fetchImpl, timeoutMs) {
  const values = new URLSearchParams(query).getAll('url');
  if (values.length !== 1) throw new HttpError(400, 'Exactly one upstream URL is required.');
  let url = validateUpstream(values[0]);
  let limit = MAX_BYTES;
  const controller = new AbortController();
  const disconnected = () => {
    if (!response.writableFinished) controller.abort(new Error('Client disconnected.'));
  };
  response.once('close', disconnected);
  let timer;
  const deadline = new Promise((_, reject) => {
    timer = setTimeout(() => {
      const error = new HttpError(504, 'Upstream request timed out.');
      controller.abort(error);
      reject(error);
    }, timeoutMs);
  });

  const forward = async () => {
    for (let redirects = 0; ; redirects++) {
      controller.signal.throwIfAborted();
      limit = Math.min(limit, url.hostname === 'gutendex.com' ? CATALOG_BYTES : MAX_BYTES);
      const upstream = await fetchImpl(url.href, {
        method: 'GET',
        redirect: 'manual',
        credentials: 'omit',
        headers: { Accept: '*/*' },
        signal: controller.signal,
      });
      const cancel = async () => {
        await upstream.body?.cancel();
        controller.signal.throwIfAborted();
      };
      if (controller.signal.aborted) {
        await cancel();
        controller.signal.throwIfAborted();
      }
      if (REDIRECTS.has(upstream.status)) {
        const location = upstream.headers.get('location');
        await cancel();
        if (redirects === 3) throw new HttpError(502, 'Upstream redirect limit exceeded.');
        if (!location) throw new HttpError(502, 'Upstream redirect has no location.');
        try {
          url = validateUpstream(new URL(location, url).href);
        } catch {
          throw new HttpError(502, 'Upstream redirect is not allowed.');
        }
        continue;
      }
      if (!upstream.ok) {
        await cancel();
        throw new HttpError(502, `Upstream returned HTTP ${upstream.status}.`);
      }
      const length = upstream.headers.get('content-length');
      if (length !== null && /^\d+$/.test(length) && BigInt(length) > BigInt(limit)) {
        await cancel();
        throw new HttpError(413, 'Upstream response exceeds the byte limit.');
      }
      const type = (upstream.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase();
      response.statusCode = upstream.status;
      response.setHeader('Content-Type', PROXY_TYPES.has(type) ? type : 'application/octet-stream');
      response.setHeader('Cache-Control', 'no-store');
      response.setHeader('X-Content-Type-Options', 'nosniff');
      // Fetch can decompress the body, so upstream Content-Length is never forwarded.
      if (!upstream.body) {
        response.end();
        return;
      }
      let bytes = 0;
      const counter = new Transform({
        transform(chunk, encoding, callback) {
          bytes += chunk.length;
          if (bytes > limit) {
            callback(new HttpError(413, 'Upstream response exceeds the byte limit.'));
          } else {
            callback(null, chunk);
          }
        },
      });
      await pipeline(Readable.fromWeb(upstream.body), counter, response, { signal: controller.signal });
      return;
    }
  };

  try {
    await Promise.race([forward(), deadline]);
  } catch (error) {
    if (controller.signal.reason instanceof HttpError) throw controller.signal.reason;
    if (error instanceof HttpError) throw error;
    throw new HttpError(502, 'Upstream request failed.');
  } finally {
    clearTimeout(timer);
    response.off('close', disconnected);
    controller.abort();
  }
}

export async function createServer({
  staticRoot = DEFAULT_ROOT,
  fetchImpl = globalThis.fetch,
  timeoutMs = 45_000,
  sessionStore,
} = {}) {
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0) {
    throw new Error('timeoutMs must be a positive integer.');
  }
  if (typeof fetchImpl !== 'function') throw new Error('fetchImpl must be a function.');
  let root;
  try {
    root = await realpath(staticRoot);
    const index = await resolveFile(root, resolve(root, 'index.html'));
    if (!(await stat(index)).isFile()) throw new Error('index.html is not a file');
  } catch {
    throw new Error(`Flutter build index.html not found or inaccessible in ${resolve(staticRoot)}. Run flutter build web first.`);
  }
  const zlibrary = createZlibraryHandler({ fetchImpl, timeoutMs, sessionStore });
  const server = http.createServer((request, response) => {
    const handle = async () => {
      const target = request.url ?? '';
      if (target.startsWith('/api/zlibrary')) {
        await zlibrary(request, response);
        return;
      }
      if (!target.startsWith('/') || target.startsWith('//')) {
        throw new HttpError(400, 'Invalid request target.');
      }
      const question = target.indexOf('?');
      const path = question < 0 ? target : target.slice(0, question);
      const proxy = path === '/api/proxy';
      const allowed = proxy ? 'GET' : 'GET, HEAD';
      if (request.method !== 'GET' && (proxy || request.method !== 'HEAD')) {
        response.setHeader('Allow', allowed);
        throw new HttpError(405, 'Method not allowed.');
      }
      if (proxy) {
        await serveProxy(request, response, question < 0 ? '' : target.slice(question + 1), fetchImpl, timeoutMs);
      } else {
        await serveStatic(request, response, root, path);
      }
    };
    handle().catch((error) => {
      if (error.code === 'EACCES') error = new HttpError(403, 'Static file is not accessible.');
      if (error.code === 'ENOENT' || error.code === 'ENOTDIR') error = new HttpError(404, 'Static file not found.');
      sendError(response, error, request.method === 'HEAD');
    });
  });
  const close = server.close;
  server.close = (callback) => {
    const closing = zlibrary.close();
    const stopped = new Promise((accept) => close.call(server, accept));
    // HTTP connections can end before aborted upstream work actually settles.
    Promise.all([stopped, closing]).then(([error]) => callback?.(error), (failure) => {
      if (callback) callback(failure);
      else server.emit('error', failure);
    });
    return server;
  };
  return server;
}

async function main() {
  const args = process.argv.slice(2);
  let port = 8787;
  if (args.length) {
    if (args.length !== 2 || args[0] !== '--port' || !/^\d+$/.test(args[1])) {
      throw new Error('Usage: node tool/serve.mjs [--port 1-65535]');
    }
    port = Number(args[1]);
    if (!Number.isSafeInteger(port) || port < 1 || port > 65535) {
      throw new Error('Port must be an integer between 1 and 65535.');
    }
  }
  const sessionStore = createZlibrarySessionStore(resolve(dirname(fileURLToPath(import.meta.url)), '../.local/zlibrary'));
  let server;
  try {
    server = await createServer({ sessionStore });
    await new Promise((accept, reject) => {
      server.once('error', reject);
      server.listen(port, '127.0.0.1', () => {
        server.off('error', reject);
        accept();
      });
    });
  } catch (error) {
    if (server) await new Promise((accept) => server.close(() => accept()));
    else sessionStore.close();
    throw error;
  }
  console.log(`Serving Flutter web at http://127.0.0.1:${port}`);
  let stopping = false;
  const shutdown = () => {
    if (stopping) return;
    stopping = true;
    const force = setTimeout(() => server.closeAllConnections(), 5_000);
    force.unref();
    server.close(() => clearTimeout(force));
    server.closeIdleConnections();
  };
  process.once('SIGINT', shutdown);
  process.once('SIGTERM', shutdown);
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  main().catch((error) => {
    console.error(`Unable to start server: ${error.message}`);
    process.exitCode = 1;
  });
}
