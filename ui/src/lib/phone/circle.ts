// What the phone reads out of the envelopes the relay serves it: which keys are whose, the member's
// Inbox (the items addressed to the circle and the items sealed to them by name) with the picks,
// answers and closes already written on it, and where the phone's own chain ends. The relay folds admission
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

/** One answer to a question, by one of its readers (docs/protocol.md, Items, Answers). */
export interface PhoneAnswer {
  hash: string;
  /** The answerer's identity, and their names from their newest card. */
  author: string;
  name?: string;
  agentName?: string;
  voice: 'person' | 'agent';
  text: string;
  created_at: string;
}

/** One reader of a named item, and the card key an answer to it is sealed to. */
export interface PhoneReader {
  identity: string;
  name?: string;
  card?: string;
}

/**
 * One entry of the member's Inbox on the phone (docs/protocol.md, Items): a question, a choice or a
 * notice addressed to the circle or sealed to the member by name.
 */
export interface PhoneItem {
  hash: string;
  kind: 'question' | 'choice' | 'notice';
  /** Who it is addressed to: the circle, or the identities it names. */
  to: 'circle' | string[];
  /** On a named item, everyone who reads it: the identities `to` names and its author. */
  readers: PhoneReader[];
  /** Which of the circle's uses it serves: `paused` is the Paused choice, `join` the join choice. */
  subject?: string;
  title: string;
  detail: string;
  /** On a choice: its options, the one that stands with no pick, and when it starts standing. */
  options: ItemOption[];
  default?: string;
  deadline?: string;
  created_at: string;
  /** The author's identity and name, and the card key a pick on their choice is sealed to beside the member's. */
  author: string;
  authorName?: string;
  authorCard?: string;
  /** The member's first pick (or Acknowledge) read for it, if any. */
  picked?: string;
  /** On a question: its readers' answers, oldest first, and whether the member wrote one of them. */
  answers: PhoneAnswer[];
  answered: boolean;
  /** On a question nobody but its author has answered: when it closes by itself. */
  lapses?: string;
  /** Its author closed it. */
  closed: boolean;
}

/** A question with no answer this long after it was sent closes by itself (docs/protocol.md, Items, Closes). */
export const QUESTION_LAPSE_MS = 7 * 86_400_000;

/** Closed by its author, or by the clock: a choice at its deadline, an unanswered question a week on. */
export function itemClosed(i: PhoneItem, now = Date.now()): boolean {
  const at = i.kind === 'choice' ? i.deadline : i.kind === 'question' ? i.lapses : undefined;
  return i.closed || (at !== undefined && Date.parse(at) <= now);
}

/** New until the member picks, acknowledges or answers it, or it closes. */
export function itemDone(i: PhoneItem, now = Date.now()): boolean {
  return i.picked !== undefined || i.answered || itemClosed(i, now);
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

interface Card {
  key: string;
  name?: string;
  agentName?: string;
}

/** Each identity's newest card a key of theirs wrote: its encryption key and its names. */
function cards(owner: Map<string, string>, envelopes: Stored[]): Map<string, Card> {
  const out = new Map<string, Card & { at: string }>();
  for (const s of envelopes) {
    if (s.envelope.kind !== 'card') continue;
    const id = owner.get(s.envelope.author);
    const b = obj(s.body);
    const key = str(b?.['encryption_key']);
    if (id === undefined || key === undefined) continue;
    const held = out.get(id);
    if (held !== undefined && s.envelope.created_at < held.at) continue;
    const name = str(b?.['name']);
    const agentName = str(b?.['agent_name']);
    out.set(id, {
      key,
      at: s.envelope.created_at,
      ...(name === undefined ? {} : { name }),
      ...(agentName === undefined ? {} : { agentName })
    });
  }
  return out;
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

/** An item's To (docs/protocol.md, Items, To): the circle, or a non-empty list of identities. */
function toOf(b: Obj | undefined): 'circle' | string[] | undefined {
  const to = b?.['to'];
  if (to === 'circle') return 'circle';
  if (!Array.isArray(to) || to.length === 0) return undefined;
  const ids = to.map(str);
  return ids.every((x) => x !== undefined) ? (ids as string[]) : undefined;
}

/**
 * The item an envelope carries, when it reached the member: one addressed to the circle, read as
 * the signed plaintext it is, by another member; one naming the member, opened with their key.
 */
async function readItem(e: Enrollment, s: Stored, author: string, card: Map<string, Card>): Promise<PhoneItem | undefined> {
  const b = obj(s.body);
  const to = toOf(b);
  if (to === undefined || (to === 'circle' ? author === e.identity : !to.includes(e.identity))) return undefined;
  const p = to === 'circle' ? obj(b?.['item']) : await open(e, b?.['sealed']);
  const kind = str(p?.['kind']);
  const title = str(p?.['title']);
  if (p === undefined || title === undefined || (kind !== 'question' && kind !== 'choice' && kind !== 'notice')) return undefined;
  const subject = str(p['subject']);
  const opts = kind === 'choice' ? options(p) : [];
  const fallback = str(p['default']);
  const deadline = str(p['deadline']);
  if (kind === 'choice' && (opts.length < 2 || !opts.some((o) => o.id === fallback))) return undefined;
  const named = (identity: string): PhoneReader => {
    const c = card.get(identity);
    return { identity, ...(c?.name === undefined ? {} : { name: c.name }), ...(c === undefined ? {} : { card: c.key }) };
  };
  const by = named(author);
  return {
    hash: s.hash,
    kind,
    to,
    readers: to === 'circle' ? [] : [...new Set([author, ...to])].map(named),
    ...(subject === undefined ? {} : { subject }),
    title,
    detail: str(p['detail']) ?? '',
    options: opts,
    ...(kind === 'choice' && fallback !== undefined ? { default: fallback } : {}),
    ...(kind === 'choice' && deadline !== undefined ? { deadline } : {}),
    created_at: s.envelope.created_at,
    author,
    ...(by.name === undefined ? {} : { authorName: by.name }),
    ...(by.card === undefined ? {} : { authorCard: by.card }),
    answers: [],
    answered: false,
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

/**
 * What an answer or a close carries (docs/protocol.md, Items, Answers, Closes): the item it names,
 * and its fields, in the clear on a circle item and opened with the member's key on a named one.
 */
async function follow(e: Enrollment, s: Stored): Promise<{ item: string; fields: Obj } | undefined> {
  const b = obj(s.body);
  const item = str(b?.['item']);
  if (b === undefined || item === undefined) return undefined;
  const fields = b['sealed'] === undefined ? b : await open(e, b['sealed']);
  return fields === undefined ? undefined : { item, fields };
}

/** Whether [identity] reads [i]: its author, everyone it names, and on a circle item every member. */
const reads = (i: PhoneItem, identity: string): boolean => identity === i.author || i.to === 'circle' || i.to.includes(identity);

/** The answers to each question by one of its readers, oldest first. */
async function answers(
  e: Enrollment,
  owner: Map<string, string>,
  card: Map<string, Card>,
  envelopes: Stored[],
  questions: Map<string, PhoneItem>
): Promise<Map<string, PhoneAnswer[]>> {
  const out = new Map<string, PhoneAnswer[]>();
  for (const s of envelopes) {
    if (s.envelope.kind !== 'item_answer') continue;
    const author = owner.get(s.envelope.author);
    const f = await follow(e, s);
    const q = f === undefined ? undefined : questions.get(f.item);
    const text = str(f?.fields['text']);
    if (author === undefined || q === undefined || text === undefined || !reads(q, author)) continue;
    const c = card.get(author);
    out.set(q.hash, [
      ...(out.get(q.hash) ?? []),
      {
        hash: s.hash,
        author,
        ...(c?.name === undefined ? {} : { name: c.name }),
        ...(c?.agentName === undefined ? {} : { agentName: c.agentName }),
        voice: str(f?.fields['voice']) === 'person' ? 'person' : 'agent',
        text,
        created_at: s.envelope.created_at
      }
    ]);
  }
  for (const l of out.values()) l.sort((a, b) => a.created_at.localeCompare(b.created_at) || a.hash.localeCompare(b.hash));
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
    const f = await follow(e, s);
    const item = f?.item;
    if (item === undefined || authors.get(item) === undefined || owner.get(s.envelope.author) !== authors.get(item)) continue;
    const p = f?.fields;
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
 * The member's Inbox as the phone reads it, newest first: every item another member addressed to
 * the circle and every item sealed to the member by name (their node's own, and those other members
 * address to them), each with the member's first pick, a question's answers and its author's close.
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
    const read = s.envelope.kind === 'item' ? await readItem(e, s, author, card) : undefined;
    if (read !== undefined) out.push(read);
  }
  const picks = await decisions(e, mine, envelopes);
  const closed = await closes(e, owner, envelopes, new Map(out.map((i) => [i.hash, i.author])));
  const said = await answers(e, owner, card, envelopes, new Map(out.filter((i) => i.kind === 'question').map((i) => [i.hash, i])));
  for (const i of out) {
    if (i.kind === 'question') {
      i.answers = said.get(i.hash) ?? [];
      i.answered = i.answers.some((a) => a.author === e.identity);
      if (!i.answers.some((a) => a.author !== i.author)) i.lapses = new Date(Date.parse(i.created_at) + QUESTION_LAPSE_MS).toISOString();
    }
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
