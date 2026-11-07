// What the phone reads out of the envelopes the relay serves it: which keys are whose, the member's
// Inbox (the choices and notices sealed to them) with the picks already written on it, and where the phone's own chain ends. The relay folds admission
// itself and refuses an append from a key it has not admitted; the phone checks every envelope's
// signature and every device body's identity signature before trusting it.
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

export interface ItemOption {
  id: string;
  label: string;
  recommended: boolean;
}

/**
 * One entry of the member's Inbox on the phone (docs/protocol.md, Items): a choice or a notice sealed
 * to the member.
 */
export interface PhoneItem {
  hash: string;
  kind: 'choice' | 'notice';
  /** Which of the circle's uses it serves: `paused` is the Paused choice, `join` the join choice. */
  subject?: string;
  title: string;
  detail: string;
  /** On a choice: its options, the one that stands with no pick, and when it starts standing. */
  options: ItemOption[];
  default?: string;
  deadline?: string;
  created_at: string;
  /** The author's identity, and the card key a pick on their choice is sealed to beside the member's. */
  author: string;
  authorCard?: string;
  /** The member's first pick (or Acknowledge) read for it, if any. */
  picked?: string;
  /** Its author closed it. */
  closed: boolean;
}

/** New until the member picks, acknowledges, its author closes it or a choice's deadline passes. */
export function itemDone(i: PhoneItem, now = Date.now()): boolean {
  return i.picked !== undefined || i.closed || (i.kind === 'choice' && i.deadline !== undefined && Date.parse(i.deadline) <= now);
}

/** The option id of an Acknowledge, the one decision a notice takes. */
export const ACKNOWLEDGE = 'acknowledge';

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

/** Which identity each admitted key speaks for: devices, mail keys and a host's dinner key, less revoked ones. */
async function identities(envelopes: Stored[]): Promise<Map<string, string>> {
  const owner = new Map<string, string>();
  const revokes: { target: string; by: string }[] = [];
  for (const s of envelopes) {
    const b = obj(s.body);
    if (b === undefined) continue;
    switch (s.envelope.kind) {
      case 'dinner': {
        const host = str(b['host']);
        if (host !== undefined && !owner.has(s.envelope.author)) owner.set(s.envelope.author, host);
        break;
      }
      case 'join': {
        const id = str(b['identity_key']);
        const d = str(b['device_key']);
        if (id !== undefined && d !== undefined) owner.set(d, id);
        break;
      }
      case 'device': {
        const id = str(b['identity_key']);
        const k = str(b['key']);
        if (id !== undefined && k !== undefined && (await verifyDevice(b as unknown as Parameters<typeof verifyDevice>[0])))
          owner.set(k, id);
        break;
      }
      case 'revoke': {
        const target = str(b['target']);
        const by = str(b['by']);
        if (target !== undefined && by !== undefined) revokes.push({ target, by });
        break;
      }
    }
  }
  // An identity revoked by itself loses every key; a device key is revoked by its own identity.
  const gone = new Set(revokes.filter((r) => r.target === r.by).map((r) => r.target));
  for (const r of revokes) if (owner.get(r.target) === r.by) owner.delete(r.target);
  for (const [k, id] of owner) if (gone.has(id)) owner.delete(k);
  return owner;
}

/** Every key of [identity]. */
const keysOf = (owner: Map<string, string>, identity: string): Set<string> =>
  new Set([...owner].filter(([, id]) => id === identity).map(([k]) => k));

/** Each identity's card key: the encryption key of the newest card a key of theirs wrote. */
function cards(owner: Map<string, string>, envelopes: Stored[]): Map<string, string> {
  const out = new Map<string, { key: string; at: string }>();
  for (const s of envelopes) {
    if (s.envelope.kind !== 'card') continue;
    const id = owner.get(s.envelope.author);
    const key = str(obj(s.body)?.['encryption_key']);
    if (id === undefined || key === undefined) continue;
    const held = out.get(id);
    if (held === undefined || s.envelope.created_at >= held.at) out.set(id, { key, at: s.envelope.created_at });
  }
  return new Map([...out].map(([id, c]) => [id, c.key]));
}

async function open(e: Enrollment, sealed: Json | undefined): Promise<Obj | undefined> {
  try {
    return obj(await openSealed(e.encryption, e.encryptionPublic, sealed as unknown as Sealed));
  } catch {
    return undefined;
  }
}

const options = (p: Obj): ItemOption[] =>
  (Array.isArray(p['options']) ? (p['options'] as Json[]) : []).flatMap((o) => {
    const id = str(obj(o)?.['id']);
    const label = str(obj(o)?.['label']);
    return id === undefined || label === undefined ? [] : [{ id, label, recommended: obj(o)?.['recommended'] === true }];
  });

/** An item envelope addressed to the member, opened: a choice or a notice; a question or a circle item is not read here. */
async function readItem(e: Enrollment, s: Stored, author: string, card: string | undefined): Promise<PhoneItem | undefined> {
  const b = obj(s.body);
  const to = Array.isArray(b?.['to']) ? (b['to'] as Json[]).map(str) : [];
  if (!to.includes(e.identity)) return undefined;
  const p = await open(e, b?.['sealed']);
  const kind = str(p?.['kind']);
  const title = str(p?.['title']);
  if (p === undefined || title === undefined || (kind !== 'choice' && kind !== 'notice')) return undefined;
  const subject = str(p['subject']);
  const opts = kind === 'choice' ? options(p) : [];
  const fallback = str(p['default']);
  const deadline = str(p['deadline']);
  if (kind === 'choice' && (opts.length < 2 || !opts.some((o) => o.id === fallback))) return undefined;
  return {
    hash: s.hash,
    kind,
    ...(subject === undefined ? {} : { subject }),
    title,
    detail: str(p['detail']) ?? '',
    options: opts,
    ...(kind === 'choice' && fallback !== undefined ? { default: fallback } : {}),
    ...(kind === 'choice' && deadline !== undefined ? { deadline } : {}),
    created_at: s.envelope.created_at,
    author,
    ...(card === undefined ? {} : { authorCard: card }),
    closed: false
  };
}

/** The member's decisions: the option each names, by the hash of the item it names. */
async function decisions(e: Enrollment, mine: Set<string>, envelopes: Stored[]): Promise<Map<string, { option: string; at: string }[]>> {
  const out = new Map<string, { option: string; at: string }[]>();
  for (const s of envelopes) {
    if (s.envelope.kind !== 'decision' || !mine.has(s.envelope.author)) continue;
    const b = obj(s.body);
    const named = str(b?.['item']);
    const option = str((await open(e, b?.['sealed']))?.['option']);
    if (named === undefined || option === undefined) continue;
    out.set(named, [...(out.get(named) ?? []), { option, at: s.envelope.created_at }]);
  }
  return out;
}

/** The close that stands on each item: the newest `person` one by its author, else the newest `agent` one. */
async function closes(
  e: Enrollment,
  owner: Map<string, string>,
  envelopes: Stored[],
  authors: Map<string, string>
): Promise<Map<string, boolean>> {
  const read = new Map<string, { closed: boolean; person: boolean; at: string; hash: string }[]>();
  for (const s of envelopes) {
    if (s.envelope.kind !== 'item_close') continue;
    const b = obj(s.body);
    const item = str(b?.['item']);
    if (item === undefined || authors.get(item) === undefined || owner.get(s.envelope.author) !== authors.get(item)) continue;
    const p = await open(e, b?.['sealed']);
    if (typeof p?.['closed'] !== 'boolean') continue;
    read.set(item, [
      ...(read.get(item) ?? []),
      { closed: p['closed'], person: str(p['voice']) === 'person', at: s.envelope.created_at, hash: s.hash }
    ]);
  }
  const out = new Map<string, boolean>();
  for (const [item, cs] of read) {
    const order = (a: { at: string; hash: string }, b: { at: string; hash: string }) =>
      a.at.localeCompare(b.at) || a.hash.localeCompare(b.hash);
    const person = cs.filter((c) => c.person).sort(order);
    const stands = person.at(-1) ?? [...cs].sort(order).at(-1);
    if (stands !== undefined) out.set(item, stands.closed);
  }
  return out;
}

/**
 * The member's Inbox as the phone reads it, newest first: every choice and notice sealed to them
 * (their node's own items, and choices and notices other members address to them), each with the
 * member's first pick and its author's close.
 */
export async function items(e: Enrollment, all: Stored[]): Promise<PhoneItem[]> {
  const envelopes = await verified(all);
  const owner = await identities(envelopes);
  const mine = keysOf(owner, e.identity);
  const card = cards(owner, envelopes);
  const out: PhoneItem[] = [];
  for (const s of envelopes) {
    const author = owner.get(s.envelope.author);
    if (author === undefined) continue;
    const read = s.envelope.kind === 'item' ? await readItem(e, s, author, card.get(author)) : undefined;
    if (read !== undefined) out.push(read);
  }
  const picks = await decisions(e, mine, envelopes);
  const closed = await closes(e, owner, envelopes, new Map(out.map((i) => [i.hash, i.author])));
  for (const i of out) {
    // The first pick of an option the item offers counts, before a choice's deadline; a notice takes only an Acknowledge.
    const first = (picks.get(i.hash) ?? []).find((d) =>
      i.kind === 'notice'
        ? d.option === ACKNOWLEDGE
        : i.options.some((o) => o.id === d.option) && (i.deadline === undefined || d.at < i.deadline)
    );
    if (first !== undefined) i.picked = first.option;
    i.closed = closed.get(i.hash) === true;
  }
  return out.sort((a, b) => b.created_at.localeCompare(a.created_at));
}

/**
 * When the member paused, while they are Paused: the phone learns the stage from the member's newest
 * summary (docs/protocol.md, The phone), and the pause began with their Paused status note.
 */
export async function pausedSince(e: Enrollment, all: Stored[]): Promise<string | undefined> {
  const envelopes = await verified(all);
  const mine = keysOf(await identities(envelopes), e.identity);
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
