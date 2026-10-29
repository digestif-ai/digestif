// The phone's keys, in IndexedDB (docs/protocol.md, The phone). Both private halves are CryptoKeys
// generated non-extractable, and the member's encryption key is imported non-extractable from the
// enrollment, so no script on this origin can read any of them out, only use them. IndexedDB keeps
// a CryptoKey as itself; localStorage could only keep bytes.
import { generatePhoneKeys } from '#lib/mail.ts';

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

function open(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(STORE);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error ?? new Error('IndexedDB did not open'));
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

/** Forget everything, for a phone being handed on: its key must also be revoked from the laptop. */
export const forget = (): Promise<unknown> => tx('readwrite', (s) => s.clear());
