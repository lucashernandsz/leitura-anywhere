import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import {
  closeSync, constants, fstatSync, fsyncSync, linkSync, lstatSync, mkdirSync,
  openSync, readFileSync, renameSync, rmdirSync, unlinkSync, writeFileSync,
} from 'node:fs';
import { dirname, join, parse, resolve, sep } from 'node:path';

const MESSAGE = 'Z-Library session storage unavailable.';
const MAGIC = Buffer.from('LZSESSION1');
const MAX_BYTES = 128 * 1024;

function invalid() { throw new Error(MESSAGE); }

function validate(records) {
  if (!Array.isArray(records) || records.length > 32) invalid();
  const tokens = new Set();
  for (const item of records) {
    if (!item || Object.keys(item).sort().join(',') !== 'expires,id,key,rememberedUntil,token'
      || typeof item.token !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(item.token)
      || tokens.has(item.token) || typeof item.id !== 'string' || !/^[1-9][0-9]{0,31}$/.test(item.id)
      || typeof item.key !== 'string' || !/^[A-Za-z0-9_-]{1,512}$/.test(item.key)
      || !Number.isSafeInteger(item.expires) || item.expires < 0
      || !Number.isSafeInteger(item.rememberedUntil) || item.rememberedUntil < item.expires) invalid();
    tokens.add(item.token);
  }
  return records;
}

// All disk operations are synchronous: each handler mutation commits before its response.
export function createZlibrarySessionStore(directory) {
  let releaseLock;
  try {
    const target = resolve(directory);
    const keyPath = join(target, 'key');
    const statePath = join(target, 'sessions');
    const uid = process.getuid();
    const checkDirectory = (create = false) => {
      let current = parse(target).root;
      for (const part of target.slice(current.length).split(sep).filter(Boolean)) {
        current = join(current, part);
        if (create) {
          try { mkdirSync(current, { mode: 0o700 }); }
          catch (error) { if (error.code !== 'EEXIST') throw error; }
        }
        const info = lstatSync(current);
        if (!info.isDirectory() || info.isSymbolicLink()) invalid();
        if (![0, uid].includes(info.uid)
          || ((info.mode & 0o022) !== 0 && !(info.uid === 0 && (info.mode & 0o1000)))) invalid();
        if (current === target && (info.uid !== uid || (info.mode & 0o7777) !== 0o700)) invalid();
      }
    };
    const read = (path, limit) => {
      let info;
      try { info = lstatSync(path); }
      catch (error) { if (error.code === 'ENOENT') return null; throw error; }
      if (!info.isFile() || info.uid !== uid || (info.mode & 0o7777) !== 0o600
        || info.nlink !== 1 || info.size > limit) invalid();
      const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
      try {
        const opened = fstatSync(fd);
        if (opened.dev !== info.dev || opened.ino !== info.ino || opened.size !== info.size
          || opened.mode !== info.mode || opened.uid !== uid || opened.nlink !== 1) invalid();
        const bytes = readFileSync(fd);
        if (bytes.length > limit) invalid();
        return bytes;
      } finally { closeSync(fd); }
    };
    const atomicWrite = (path, bytes, replace) => {
      const temporary = join(target, `.tmp-${randomBytes(16).toString('hex')}`);
      let fd;
      try {
        fd = openSync(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
        writeFileSync(fd, bytes);
        fsyncSync(fd);
        closeSync(fd);
        fd = undefined;
        checkDirectory();
        if (replace) renameSync(temporary, path);
        else linkSync(temporary, path); // Never replace an existing encryption key.
        if (!replace) unlinkSync(temporary);
        const directoryFd = openSync(dirname(path), constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
        try { fsyncSync(directoryFd); } finally { closeSync(directoryFd); }
      } finally {
        if (fd !== undefined) closeSync(fd);
        try { unlinkSync(temporary); } catch (error) { if (error.code !== 'ENOENT') throw error; }
      }
    };
    checkDirectory(true);
    const lockPath = join(target, 'writer.lock');
    // Atomic acquisition; never reclaim an existing lock, even after a crash.
    mkdirSync(lockPath, { mode: 0o700 });
    let closed = false;
    releaseLock = () => {
      if (closed) return;
      closed = true;
      // Only our owner removes this empty directory. No stale-lock check/unlink race.
      rmdirSync(lockPath);
    };
    let key = read(keyPath, 32);
    if (key === null) {
      if (read(statePath, MAX_BYTES) !== null) invalid();
      key = randomBytes(32);
      atomicWrite(keyPath, key, false);
    }
    if (key.length !== 32) invalid();
    const load = () => {
      if (closed) invalid();
      checkDirectory();
      const diskKey = read(keyPath, 32);
      if (!diskKey || !diskKey.equals(key)) invalid();
      const bytes = read(statePath, MAX_BYTES);
      if (bytes === null) return [];
      if (bytes.length < MAGIC.length + 28 || !bytes.subarray(0, MAGIC.length).equals(MAGIC)) invalid();
      const decipher = createDecipheriv('aes-256-gcm', key, bytes.subarray(MAGIC.length, MAGIC.length + 12));
      decipher.setAAD(MAGIC);
      decipher.setAuthTag(bytes.subarray(MAGIC.length + 12, MAGIC.length + 28));
      const plaintext = Buffer.concat([decipher.update(bytes.subarray(MAGIC.length + 28)), decipher.final()]);
      return validate(JSON.parse(plaintext.toString('utf8')));
    };
    load(); // Reject corrupt or insecure state at startup, before accepting requests.
    return {
      load() {
        try { return load(); } catch { throw new Error(MESSAGE); }
      },
      save(records) {
        try {
          validate(records);
          load(); // Never overwrite corrupted state or continue with a replaced key.
          const iv = randomBytes(12);
          const cipher = createCipheriv('aes-256-gcm', key, iv);
          cipher.setAAD(MAGIC);
          const encrypted = Buffer.concat([cipher.update(JSON.stringify(records), 'utf8'), cipher.final()]);
          atomicWrite(statePath, Buffer.concat([MAGIC, iv, cipher.getAuthTag(), encrypted]), true);
        } catch { throw new Error(MESSAGE); }
      },
      close() {
        try { releaseLock(); } catch { throw new Error(MESSAGE); }
      },
    };
  } catch {
    try { releaseLock?.(); } catch { /* Leave an uncertain lock in place. */ }
    throw new Error(MESSAGE);
  }
}
