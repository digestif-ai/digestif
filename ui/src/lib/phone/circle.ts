// What the phone reads out of the envelopes the relay serves it: which keys are this member's, the
// member's asks and the decisions already written on them, and where the phone's own chain ends.
// The relay folds admission itself and refuses an append from a key it has not admitted; the phone
// checks every envelope's signature and every device body's identity signature before trusting it.
import {
  importEncryptionKey,
  keyTextEd25519,
  openEnrollment,
  openSealed,
  verifyDevice,
  verifyEnvelope,
  type Json,
  type Sealed
} from '#lib/mail.ts';
import type { Enrollment, PhoneKeys } from './keystore.ts';
import type { Stored } from './relay.ts';

export interface AskOption {
  id: string;
  label: string;
  recommended: boolean;
}

export interface Ask {
  hash: string;
  title: string;
  detail: string;
  options: AskOption[];
  on_no_answer: string;
  lapses_at: string;
  created_at: string;
  /** The first decision read for it and the option it names, if any. */
  answered?: string;
}

type Obj = Record<string, Json | undefined>;
const obj = (j: Json | undefined): Obj | undefined => (j !== null && typeof j === 'object' && !Array.isArray(j) ? (j as Obj) : undefined);
const str = (j: Json | undefined): string | undefined => (typeof j === 'string' ? j : undefined);

async function verified(envelopes: Stored[]): Promise<Stored[]> {
  const out: Stored[] = [];
  for (const s of envelopes) {
    if (s.body === undefined) continue;
    try {
      if ((await verifyEnvelope({ envelope: s.envelope, body: s.body })) === s.hash) out.push(s);
    } catch {
      // a relay served something that does not verify: not the member's word
    }
  }
  return out;
}

/** The phone's device envelope, once the laptop has appended it, and the enrollment it carries. */
export async function findEnrollment(keys: PhoneKeys, envelopes: Stored[]): Promise<Enrollment | undefined> {
  const me = keyTextEd25519(keys.ed25519);
  for (const s of await verified(envelopes)) {
    const b = obj(s.body);
    if (s.envelope.kind !== 'device' || b === undefined || str(b['key']) !== me || b['enrollment'] === undefined) continue;
    try {
      if (!(await verifyDevice(b as unknown as Parameters<typeof verifyDevice>[0]))) continue;
      const e = await openEnrollment(keys.sealing, keys.x25519, { enrollment: b['enrollment'] as unknown as Sealed });
      if (e.identityKey !== str(b['identity_key'])) continue;
      const k = await importEncryptionKey(e.encryptionKey);
      return { encryption: k.privateKey, encryptionPublic: k.publicRaw, identity: e.identityKey, relays: e.relays };
    } catch {
      // sealed to another phone, or damaged
    }
  }
  return undefined;
}

/** Every key of [identity]: its devices and mail keys, unless revoked by it. */
async function memberKeys(identity: string, envelopes: Stored[]): Promise<Set<string>> {
  const keys = new Set<string>();
  const revoked = new Set<string>();
  for (const s of envelopes) {
    const b = obj(s.body);
    if (b === undefined) continue;
    switch (s.envelope.kind) {
      case 'dinner':
        if (str(b['host']) === identity) keys.add(s.envelope.author);
        break;
      case 'join':
        if (str(b['identity_key']) === identity) {
          const d = str(b['device_key']);
          if (d !== undefined) keys.add(d);
        }
        break;
      case 'device':
        if (str(b['identity_key']) === identity && (await verifyDevice(b as unknown as Parameters<typeof verifyDevice>[0]))) {
          const k = str(b['key']);
          if (k !== undefined) keys.add(k);
        }
        break;
      case 'revoke':
        if (str(b['by']) === identity) {
          const t = str(b['target']);
          if (t !== undefined) revoked.add(t);
        }
        break;
    }
  }
  if (revoked.has(identity)) return new Set();
  for (const r of revoked) keys.delete(r);
  return keys;
}

async function open(e: Enrollment, sealed: Json | undefined): Promise<Obj | undefined> {
  try {
    return obj(await openSealed(e.encryption, e.encryptionPublic, sealed as unknown as Sealed));
  } catch {
    return undefined;
  }
}

/** The member's asks, newest first, each with the first decision read for it. */
export async function asks(e: Enrollment, all: Stored[]): Promise<Ask[]> {
  const envelopes = await verified(all);
  const mine = await memberKeys(e.identity, envelopes);
  const answers = new Map<string, string>();
  for (const s of envelopes) {
    if (s.envelope.kind !== 'decision' || !mine.has(s.envelope.author)) continue;
    const ask = str(obj(s.body)?.['ask']);
    const p = await open(e, obj(s.body)?.['sealed']);
    const option = str(p?.['option']);
    if (ask !== undefined && option !== undefined && !answers.has(ask)) answers.set(ask, option);
  }
  const out: Ask[] = [];
  for (const s of envelopes) {
    if (s.envelope.kind !== 'ask' || !mine.has(s.envelope.author)) continue;
    const p = await open(e, obj(s.body)?.['sealed']);
    const title = str(p?.['title']);
    const options = Array.isArray(p?.['options']) ? (p['options'] as Json[]) : [];
    const lapses = str(p?.['lapses_at']);
    const noAnswer = str(p?.['on_no_answer']);
    if (p === undefined || title === undefined || lapses === undefined || noAnswer === undefined) continue;
    const answered = answers.get(s.hash);
    out.push({
      hash: s.hash,
      title,
      detail: str(p['detail']) ?? '',
      options: options.flatMap((o) => {
        const id = str(obj(o)?.['id']);
        const label = str(obj(o)?.['label']);
        return id === undefined || label === undefined ? [] : [{ id, label, recommended: obj(o)?.['recommended'] === true }];
      }),
      on_no_answer: noAnswer,
      lapses_at: lapses,
      created_at: s.envelope.created_at,
      ...(answered === undefined ? {} : { answered })
    });
  }
  return out.sort((a, b) => b.created_at.localeCompare(a.created_at));
}

/**
 * When the member paused, while they are Paused: the phone learns the stage from the member's newest
 * summary (docs/protocol.md, The phone), and the pause began with their Paused status note.
 */
export async function pausedSince(e: Enrollment, all: Stored[]): Promise<string | undefined> {
  const envelopes = await verified(all);
  const mine = await memberKeys(e.identity, envelopes);
  const summaries = envelopes
    .filter((s) => s.envelope.kind === 'summary' && mine.has(s.envelope.author))
    .sort((a, b) => b.envelope.created_at.localeCompare(a.envelope.created_at));
  if (str(obj(summaries[0]?.body)?.['stage']) !== 'paused') return undefined;
  const note = summaries.find((s) => str(obj(s.body)?.['status']) === 'paused');
  return (note ?? summaries[0])?.envelope.created_at;
}

/** Where the phone's own chain ends: the next seq and the hash before it. */
export function chainEnd(keys: PhoneKeys, envelopes: Stored[]): { seq: number; prev?: string } {
  const me = keyTextEd25519(keys.ed25519);
  let last: Stored | undefined;
  for (const s of envelopes) if (s.envelope.author === me && (last === undefined || s.envelope.seq > last.envelope.seq)) last = s;
  return last === undefined ? { seq: 1 } : { seq: last.envelope.seq + 1, prev: last.hash };
}
