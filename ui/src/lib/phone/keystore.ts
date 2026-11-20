// The phone's keys, in IndexedDB (docs/protocol.md, The phone). Both private halves are CryptoKeys
// generated non-extractable, and the member's encryption key is imported non-extractable from the
// enrollment, so no script on this origin can read any of them out, only use them. IndexedDB keeps
// a CryptoKey as itself; localStorage could only keep bytes. Beside them, the relay's log as the
// phone last read it (log.ts), so a load reads only what is newer.
import { generatePhoneKeys } from '#lib/mail.ts';
import type { Held } from './log.ts';

export interface PhoneKeys {
  signing: CryptoKey;
  sealing: CryptoKey;
  ed25519: Uint8Array<ArrayBuffer>;
  x25519: Uint8Array<ArrayBuffer>;
  code: string;
}

export interface Enrollment {
  encryption: CryptoKey;
  encryptionPublic: Uint8Array<ArrayBuffer>;
  identity: string;
  relays: string[];
}

const DB = 'digestif-phone';
const STORE = 'keys';
/** Every envelope the phone holds, keyed by relay_id, so reading the store back is relay order. */
const LOG = 'log';
/** The relay position the held log runs through, under STORE. */
const AFTER = 'log_after';

function open(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB, 2);
    req.onupgradeneeded = () => {
      for (const name of [STORE, LOG]) if (!req.result.objectStoreNames.contains(name)) req.result.createObjectStore(name);
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error ?? new Error('IndexedDB did not open'));
  });
}

function done(t: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    t.oncomplete = () => resolve();
    t.onerror = () => reject(t.error ?? new Error('IndexedDB transaction failed'));
    t.onabort = () => reject(t.error ?? new Error('IndexedDB transaction aborted'));
  });
}

async function tx<T>(mode: IDBTransactionMode, f: (s: IDBObjectStore) => IDBRequest): Promise<T> {
  const db = await open();
  try {
    return await new Promise<T>((resolve, reject) => {
      const req = f(db.transaction(STORE, mode).objectStore(STORE));
      req.onsuccess = () => resolve(req.result as T);
      req.onerror = () => reject(req.error ?? new Error('IndexedDB request failed'));
    });
  } finally {
    db.close();
  }
}

const get = <T>(name: string): Promise<T | undefined> => tx<T | undefined>('readonly', (s) => s.get(name));
const put = (name: string, value: unknown): Promise<unknown> => tx('readwrite', (s) => s.put(value, name));

/** This phone's keys, made the first time they are asked for. */
export async function phoneKeys(): Promise<PhoneKeys> {
  const held = await get<PhoneKeys>('phone');
  if (held !== undefined) return held;
  const k = await generatePhoneKeys();
  const keys: PhoneKeys = {
    signing: k.signing.privateKey,
    sealing: k.sealing.privateKey,
    ed25519: k.ed25519,
    x25519: k.x25519,
    code: k.code
  };
  await put('phone', keys);
  return keys;
}

export const enrollment = (): Promise<Enrollment | undefined> => get<Enrollment>('enrollment');
export const saveEnrollment = (e: Enrollment): Promise<unknown> => put('enrollment', e);

/** The log the phone holds, in relay order, and the relay position it runs through. */
export async function heldLog(): Promise<{ log: Held[]; after: number }> {
  const db = await open();
  try {
    const t = db.transaction([STORE, LOG], 'readonly');
    const after = t.objectStore(STORE).get(AFTER);
    const log = t.objectStore(LOG).getAll();
    await done(t);
    return { log: log.result as Held[], after: typeof after.result === 'number' ? after.result : 0 };
  } finally {
    db.close();
  }
}

/** Keep [changed], new envelopes and ones a retract emptied, and the position the log now runs through, in one transaction. */
export async function saveLog(changed: Held[], after: number): Promise<void> {
  const db = await open();
  try {
    const t = db.transaction([STORE, LOG], 'readwrite');
    const log = t.objectStore(LOG);
    for (const h of changed) log.put(h, h.stored.relay_id);
    t.objectStore(STORE).put(after, AFTER);
    await done(t);
  } finally {
    db.close();
  }
}

/** Forget everything, for a phone being handed on: its key must also be revoked from the laptop. */
export async function forget(): Promise<void> {
  const db = await open();
  try {
    const t = db.transaction([STORE, LOG], 'readwrite');
    t.objectStore(STORE).clear();
    t.objectStore(LOG).clear();
    await done(t);
  } finally {
    db.close();
  }
}
