import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  chmodSync, linkSync, lstatSync, mkdirSync, mkdtempSync, readFileSync,
  readdirSync, rmSync, symlinkSync, unlinkSync, writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { createZlibrarySessionStore } from './zlibrary_session_store.mjs';

const FIXTURE = { token: 't'.repeat(43), id: '735192', key: 'fixture_remix_key',
  expires: 1_800_000, rememberedUntil: 2_592_000_000 };
const MESSAGE = { message: 'Z-Library session storage unavailable.' };

function directory(t) {
  const path = mkdtempSync(join(tmpdir(), 'leitura-zlibrary-store-'));
  t.after(() => {
    chmodSync(path, 0o700);
    rmSync(path, { recursive: true, force: true });
  });
  return path;
}

test('AES-GCM state survives restart with private files and contains no plaintext credentials', (t) => {
  const path = directory(t);
  const store = createZlibrarySessionStore(path);
  assert.deepEqual(store.load(), []);
  store.save([FIXTURE]);
  assert.throws(() => createZlibrarySessionStore(path), MESSAGE);
  const first = readFileSync(join(path, 'sessions'));
  store.save([FIXTURE]);
  assert.notDeepEqual(readFileSync(join(path, 'sessions')), first, 'Each save needs a fresh nonce.');
  assert.equal(lstatSync(path).mode & 0o777, 0o700);
  assert.deepEqual(readdirSync(path).sort(), ['key', 'sessions', 'writer.lock']);
  assert.equal(readFileSync(join(path, 'key')).length, 32);
  for (const name of ['key', 'sessions']) {
    assert.equal(lstatSync(join(path, name)).mode & 0o777, 0o600);
    const bytes = readFileSync(join(path, name));
    for (const value of [FIXTURE.token, FIXTURE.id, FIXTURE.key, 'fixture-password-not-real', 'fixture@example.invalid']) {
      assert.equal(bytes.includes(Buffer.from(value)), false);
    }
  }
  store.close();
  store.close();
  assert.throws(() => store.load(), MESSAGE);
  assert.throws(() => store.save([]), MESSAGE);
  const restarted = createZlibrarySessionStore(path);
  assert.deepEqual(restarted.load(), [FIXTURE]);
  store.close(); // A repeated close must not release the new owner's lock.
  assert.throws(() => createZlibrarySessionStore(path), MESSAGE);
  restarted.save([]);
  restarted.close();
  const final = createZlibrarySessionStore(path);
  assert.deepEqual(final.load(), []);
  final.close();
});

test('a second process cannot write; abandoned locks fail closed without recovery', (t) => {
  const script = `import { createZlibrarySessionStore } from ${JSON.stringify(new URL('./zlibrary_session_store.mjs', import.meta.url).href)};
    createZlibrarySessionStore(process.argv[1]);`;
  const path = directory(t);
  const store = createZlibrarySessionStore(path);
  store.save([FIXTURE]);
  const before = readFileSync(join(path, 'sessions'));
  const denied = spawnSync(process.execPath, ['--input-type=module', '-e', script, path], { encoding: 'utf8' });
  assert.equal(denied.status, 1);
  assert.match(denied.stderr, /Z-Library session storage unavailable/);
  assert.deepEqual(readFileSync(join(path, 'sessions')), before);
  store.close();
  const abandoned = spawnSync(process.execPath, ['--input-type=module', '-e', script, path], { encoding: 'utf8' });
  assert.equal(abandoned.status, 0, abandoned.stderr);
  for (let index = 0; index < 2; index++) assert.throws(() => createZlibrarySessionStore(path), MESSAGE);
  assert.equal(lstatSync(join(path, 'writer.lock')).isDirectory(), true);
  assert.deepEqual(readFileSync(join(path, 'sessions')), before);
});

test('failed startup releases only its acquired lock, never an existing lock', (t) => {
  const path = directory(t);
  writeFileSync(join(path, 'key'), 'bad', { mode: 0o600 });
  assert.throws(() => createZlibrarySessionStore(path), MESSAGE);
  assert.deepEqual(readdirSync(path), ['key']);
  mkdirSync(join(path, 'writer.lock'), { mode: 0o700 });
  assert.throws(() => createZlibrarySessionStore(path), MESSAGE);
  assert.equal(lstatSync(join(path, 'writer.lock')).isDirectory(), true);
});

test('uncertain lock release fails closed without deleting lock contents or retrying removal', (t) => {
  const path = directory(t);
  const store = createZlibrarySessionStore(path);
  const marker = join(path, 'writer.lock', 'unexpected');
  writeFileSync(marker, 'fixture');
  assert.throws(() => store.close(), MESSAGE);
  assert.throws(() => store.save([]), MESSAGE);
  assert.throws(() => createZlibrarySessionStore(path), MESSAGE);
  assert.equal(readFileSync(marker, 'utf8'), 'fixture');
  unlinkSync(marker);
  store.close();
  assert.throws(() => createZlibrarySessionStore(path), MESSAGE);
});

test('corrupt, truncated, tampered and wrong-key state fail closed without overwriting files', (t) => {
  for (const kind of ['header', 'nonce', 'tag', 'ciphertext', 'truncated', 'key', 'missing-key']) {
    const path = directory(t);
    const store = createZlibrarySessionStore(path);
    store.save([FIXTURE]);
    const statePath = join(path, 'sessions');
    const keyPath = join(path, 'key');
    if (kind === 'missing-key') unlinkSync(keyPath);
    else if (kind === 'key') writeFileSync(keyPath, Buffer.alloc(32, 7));
    else {
      let bytes = readFileSync(statePath);
      if (kind === 'truncated') bytes = bytes.subarray(0, 20);
      else bytes[{ header: 0, nonce: 10, tag: 22, ciphertext: 40 }[kind]] ^= 1;
      writeFileSync(statePath, bytes);
    }
    const before = readFileSync(statePath);
    const keyBefore = kind === 'missing-key' ? null : readFileSync(keyPath);
    assert.throws(() => store.load(), MESSAGE);
    assert.throws(() => store.save([]), MESSAGE);
    store.close();
    assert.throws(() => createZlibrarySessionStore(path), MESSAGE);
    assert.deepEqual(readFileSync(statePath), before);
    if (keyBefore) assert.deepEqual(readFileSync(keyPath), keyBefore);
    else assert.equal(readdirSync(path).includes('key'), false);
  }
});

test('an existing corrupt key is never regenerated, even without state', (t) => {
  const path = directory(t);
  const keyPath = join(path, 'key');
  writeFileSync(keyPath, 'corrupt-fixture-key', { mode: 0o600 });
  assert.throws(() => createZlibrarySessionStore(path), MESSAGE);
  assert.equal(readFileSync(keyPath, 'utf8'), 'corrupt-fixture-key');
});

test('insecure and unreadable directory/key/state modes fail closed at startup and save', (t) => {
  for (const name of ['', 'key', 'sessions']) {
    for (const mode of [0o777, 0o644, 0o000]) {
      const path = directory(t);
      const store = createZlibrarySessionStore(path);
      store.save([FIXTURE]);
      const target = join(path, name);
      chmodSync(target, mode);
      try {
        assert.throws(() => store.load(), MESSAGE);
        assert.throws(() => store.save([]), MESSAGE);
        if (name !== '') store.close();
        assert.throws(() => createZlibrarySessionStore(path), MESSAGE);
      } finally {
        chmodSync(target, name === '' ? 0o700 : 0o600);
        store.close();
      }
    }
  }
});

test('symlinked directories, ancestors, state and keys and hardlinked files are rejected', (t) => {
  for (const name of ['key', 'sessions']) {
    for (const hardlink of [false, true]) {
      const path = directory(t);
      const other = directory(t);
      const store = createZlibrarySessionStore(path);
      store.save([FIXTURE]);
      const target = join(path, name);
      const copy = join(other, name);
      writeFileSync(copy, readFileSync(target), { mode: 0o600 });
      unlinkSync(target);
      if (hardlink) linkSync(copy, target);
      else symlinkSync(copy, target);
      assert.throws(() => store.save([]), MESSAGE);
      store.close();
      assert.throws(() => createZlibrarySessionStore(path), MESSAGE);
    }
  }
  const path = directory(t);
  const other = directory(t);
  symlinkSync(other, join(path, 'linked'));
  assert.throws(() => createZlibrarySessionStore(join(path, 'linked')), MESSAGE);
  assert.throws(() => createZlibrarySessionStore(join(path, 'linked', 'nested')), MESSAGE);
  assert.deepEqual(readdirSync(other), []);
  mkdirSync(join(path, 'insecure'), { mode: 0o777 });
  chmodSync(join(path, 'insecure'), 0o777);
  assert.throws(() => createZlibrarySessionStore(join(path, 'insecure', 'nested')), MESSAGE);
});

test('strict persisted schema rejects extra credentials, duplicate tokens and excessive records', (t) => {
  const store = createZlibrarySessionStore(directory(t));
  for (const records of [null, {}, [null], [{ ...FIXTURE, password: 'fixture-password-not-real' }],
    [{ ...FIXTURE, email: 'fixture@example.invalid' }], [FIXTURE, FIXTURE], Array(33).fill(FIXTURE),
    [{ ...FIXTURE, token: 'bad' }], [{ ...FIXTURE, key: 'bad;cookie' }], [{ ...FIXTURE, id: 1 }],
    [{ ...FIXTURE, expires: -1 }], [{ ...FIXTURE, rememberedUntil: 0 }]]) {
    assert.throws(() => store.save(records), MESSAGE);
    assert.deepEqual(store.load(), []);
  }
});
