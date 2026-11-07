// What the phone reads out of the envelopes the relay serves it: which keys are this member's, the
// node's own choices for the member and the picks already written on them, and where the phone's own chain ends.
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

export interface ChoiceOption {
  id: string;
  label: string;
  recommended: boolean;
}

/** One of the node's own choices (docs/protocol.md, Items): an item of kind choice addressed to the member alone. */
export interface Choice {
  hash: string;
  /** Which of the circle's uses it serves when the node names one: `paused` is the Paused choice. */
  subject?: string;
  title: string;
  detail: string;
  options: ChoiceOption[];
  /** The id of the option that stands with no pick. */
  default: string;
  /** When the default takes effect. Absent on a choice that stands on its default for as long as nobody picks. */
  deadline?: string;
  created_at: string;
  /** The first pick read for it and the option it names, if any. */
  picked?: string;
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

/** The first pick each of the member's keys wrote on a choice, by the choice's hash (docs/protocol.md, Picks). */
async function picks(e: Enrollment, envelopes: Stored[], mine: Set<string>): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  for (const s of envelopes) {
    if (s.envelope.kind !== 'decision' || !mine.has(s.envelope.author)) continue;
    const item = str(obj(s.body)?.['item']);
    if (item === undefined || out.has(item)) continue;
    const option = str((await open(e, obj(s.body)?.['sealed']))?.['option']);
    if (option !== undefined) out.set(item, option);
  }
  return out;
}

function options(j: Json | undefined): ChoiceOption[] {
  return (Array.isArray(j) ? j : []).flatMap((o) => {
    const id = str(obj(o)?.['id']);
    const label = str(obj(o)?.['label']);
    return id === undefined || label === undefined ? [] : [{ id, label, recommended: obj(o)?.['recommended'] === true }];
  });
}

/** The choice an item envelope carries, when it is one addressed to [identity] alone and opens with the enrollment's key. */
async function choiceOf(e: Enrollment, s: Stored): Promise<Omit<Choice, 'picked'> | undefined> {
  const b = obj(s.body);
  const to = b?.['to'];
  if (!Array.isArray(to) || to.length !== 1 || to[0] !== e.identity) return undefined;
  const p = await open(e, b?.['sealed']);
  const title = str(p?.['title']);
  const fallback = str(p?.['default']);
  if (p === undefined || p['kind'] !== 'choice' || title === undefined || title === '' || fallback === undefined) return undefined;
  const opts = options(p['options']);
  if (opts.length < 2 || !opts.some((o) => o.id === fallback)) return undefined;
  const subject = str(p['subject']);
  const deadline = str(p['deadline']);
  return {
    hash: s.hash,
    ...(subject === undefined ? {} : { subject }),
    title,
    detail: str(p['detail']) ?? '',
    options: opts,
    default: fallback,
    ...(deadline === undefined ? {} : { deadline }),
    created_at: s.envelope.created_at
  };
}

/** The node's own choices for the member, newest first, each with the first pick read for it. */
export async function choices(e: Enrollment, all: Stored[]): Promise<Choice[]> {
  const envelopes = await verified(all);
  const mine = await memberKeys(e.identity, envelopes);
  const picked = await picks(e, envelopes, mine);
  const out: Choice[] = [];
  for (const s of envelopes) {
    if (s.envelope.kind !== 'item' || !mine.has(s.envelope.author)) continue;
    const c = await choiceOf(e, s);
    if (c === undefined) continue;
    const pick = picked.get(s.hash);
    out.push({ ...c, ...(pick === undefined ? {} : { picked: pick }) });
  }
  return out.sort((a, b) => b.created_at.localeCompare(a.created_at));
}

/** A pick on one of the node's own choices (docs/protocol.md, Picks), the node's own construction. */
export { pickBody } from '#lib/mail.ts';

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
