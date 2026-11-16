// What the phone reads out of the envelopes the relay serves it: which keys are whose, the member's
// Inbox (the items addressed to the circle and the items sealed to them by name) with the picks,
// answers and closes already written on it, the deny list their node shared with the phone, and
// where the phone's own chain ends. The relay folds admission
// itself and refuses an append from a key it has not admitted; the phone checks every envelope's
// signature and every device body's identity signature before trusting it.
import {
  importEncryptionKey,
  jcs,
  keyRawEd25519,
  keyTextEd25519,
  openEnrollment,
  openSealed,
  unb64url,
  verifyDevice,
  verifyEnvelope,
  type Json,
  type Sealed
} from '#lib/mail.ts';
import type { DenyEntry } from '#lib/deny.ts';
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

/** The protocol's one time form: UTC with a Z, whole seconds or with a fraction of one to three digits (docs/protocol.md, Encoding). */
const Z_FORM = /^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])T([01]\d|2[0-3]):[0-5]\d:[0-5]\d(\.\d{1,3})?Z$/;

/** Whether `s` is in the protocol's Z form and names a day its month has, as Time_fmt.is_z on the node. */
export function isZForm(s: string): boolean {
  if (!Z_FORM.test(s)) return false;
  const y = Number(s.slice(0, 4));
  const m = Number(s.slice(5, 7));
  const d = Number(s.slice(8, 10));
  const leap = (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
  const days = m === 2 ? (leap ? 29 : 28) : [4, 6, 9, 11].includes(m) ? 30 : 31;
  return d <= days;
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

const subtle = globalThis.crypto.subtle;

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

/**
 * An admitted device or mail key: whose it is, and once a revoke stops it, the cutoff a node still
 * reads it inside (docs/protocol.md, revoke): the highest `seq` for a device key, the hashes
 * `mail_read` lists for a mail key, since a mail key is chainless.
 */
interface Key {
  identity: string;
  role: 'device' | 'mail';
  revoked: boolean;
  afterSeq?: number;
  mailRead?: Set<string>;
}
type Keys = Map<string, Key>;

/** Whether [s], by the revoked key [k], is inside its cutoff (node/core/fold.ml, within_cutoff). */
const withinCutoff = (k: Key, s: Stored): boolean =>
  k.afterSeq !== undefined ? s.envelope.seq <= k.afterSeq : (k.mailRead?.has(s.hash) ?? false);

/** Whether [s]'s author is revoked and [s] lies past its cutoff: no node reads it (fold.ml, past_cutoff). */
function pastCutoff(keys: Keys, s: Stored): boolean {
  const k = keys.get(s.envelope.author);
  return k !== undefined && k.revoked && !withinCutoff(k, s);
}

/** The identity [s] speaks for: its author's, while the key is unrevoked or [s] is inside its cutoff (fold.ml, author_in_force). */
function speaker(keys: Keys, s: Stored): string | undefined {
  const k = keys.get(s.envelope.author);
  return k === undefined || pastCutoff(keys, s) ? undefined : k.identity;
}

/** The fold's order, (created_at, hash) as bytes (docs/protocol.md), the same as the node's. */
const bytes = (x: string, y: string) => (x < y ? -1 : x > y ? 1 : 0);
const foldOrder = (a: { at: string; hash: string }, b: { at: string; hash: string }) => bytes(a.at, b.at) || bytes(a.hash, b.hash);

/**
 * The order follow-ups are listed and picked in, the same as the node's (api.ml, follow_up_order):
 * one signed in the Z form first, by its signed time and then hash as bytes; any other after, in the
 * fold order. In the Z form, Date.parse is exact and agrees with the node's created_unix (DIG-99).
 */
export const followUpOrder = (a: { at: string; hash: string }, b: { at: string; hash: string }): number => {
  const za = isZForm(a.at);
  const zb = isZForm(b.at);
  if (za !== zb) return za ? -1 : 1;
  return za ? Date.parse(a.at) - Date.parse(b.at) || bytes(a.hash, b.hash) : foldOrder(a, b);
};

/** How long after a join the device key that wrote its dinner may revoke the identity it admitted (fold.ml, host_device_window). */
const HOST_DEVICE_WINDOW_MS = 7 * 86_400_000;

const HASH = /^sha256:[0-9a-f]{64}$/;

interface Admission {
  keys: Keys;
  /** dinner hash -> its host identity and the device key that wrote it */
  dinners: Map<string, { host: string; author: string }>;
  /** identity -> the dinner its join named, and the join's created_at */
  joins: Map<string, { dinner: string; at: string }>;
}

/** A revoke a node applies: the keys it stops, and its cutoffs. */
interface Revoke {
  stopped: [string, Key][];
  afterSeq: Obj;
  mailRead: Obj;
}

/** Whether the revoke body [b] is signed by its `by` over JCS({target, by, after_seq, mail_read}). */
async function revokeSigned(b: Obj): Promise<boolean> {
  try {
    const by = await subtle.importKey('raw', keyRawEd25519(str(b['by']) ?? ''), { name: 'Ed25519' }, false, ['verify']);
    const claim = { target: b['target'], by: b['by'], after_seq: b['after_seq'], mail_read: b['mail_read'] };
    return await subtle.verify({ name: 'Ed25519' }, by, unb64url(str(b['signature']) ?? ''), new TextEncoder().encode(jcs(claim)));
  } catch {
    return false;
  }
}

/**
 * The keys a revoke stops, when [s] is one a node applies (fold.ml, apply_revoke): a device or mail
 * key revoked by its own identity, or an identity revoked by itself, by the host whose dinner
 * admitted it, or within the window by the device key that wrote that dinner; authored by a key in
 * force, signed by `by`, and with `after_seq` and `mail_read` naming only keys it stops.
 */
async function revokeStops(a: Admission, s: Stored): Promise<Revoke | undefined> {
  const b = obj(s.body);
  const target = str(b?.['target']);
  const by = str(b?.['by']);
  const afterSeq = obj(b?.['after_seq']);
  const mailRead = obj(b?.['mail_read']);
  if (b === undefined || target === undefined || by === undefined || afterSeq === undefined || mailRead === undefined) return undefined;
  const author = a.keys.get(s.envelope.author);
  if (author === undefined || pastCutoff(a.keys, s)) return undefined;
  const targetKey = a.keys.get(target);
  // Who may author it: a device key of `by`, or, for the dinner's device key, that key itself.
  let byItself = false;
  let stopped: [string, Key][];
  if (targetKey !== undefined) {
    if (targetKey.identity !== by) return undefined;
    stopped = [[target, targetKey]];
  } else {
    stopped = [...a.keys].filter(([, k]) => k.identity === target);
    const join = a.joins.get(target);
    const dinner = join === undefined ? undefined : a.dinners.get(join.dinner);
    if (stopped.length === 0) return undefined;
    if (by !== target && dinner?.host !== by) {
      const inWindow = join !== undefined && Date.parse(s.envelope.created_at) <= Date.parse(join.at) + HOST_DEVICE_WINDOW_MS;
      if (dinner?.author !== by || !inWindow) return undefined;
      byItself = true;
    }
  }
  if (byItself ? s.envelope.author !== by : author.role !== 'device' || author.identity !== by) return undefined;
  const stops = (role: Key['role'], key: string) => stopped.some(([k, x]) => k === key && x.role === role);
  for (const [k, v] of Object.entries(afterSeq))
    if (!stops('device', k) || typeof v !== 'number' || !Number.isInteger(v) || v < 0) return undefined;
  for (const [k, v] of Object.entries(mailRead))
    if (!stops('mail', k) || !Array.isArray(v) || !v.every((h) => typeof h === 'string' && HASH.test(h))) return undefined;
  if (!(await revokeSigned(b))) return undefined;
  return { stopped, afterSeq, mailRead };
}

/** Records a revoke's cutoff on each key it stops; two revokes stopping one key leave the lower cutoff, and for a mail key the hashes both list (fold.ml, record_cutoff). */
function recordCutoffs(r: Revoke): void {
  for (const [key, k] of r.stopped) {
    k.revoked = true;
    if (k.role === 'device') {
      const v = r.afterSeq[key];
      const cutoff = typeof v === 'number' ? v : 0;
      k.afterSeq = k.afterSeq === undefined ? cutoff : Math.min(k.afterSeq, cutoff);
    } else {
      const v = r.mailRead[key];
      const listed = new Set(Array.isArray(v) ? (v as string[]) : []);
      k.mailRead = k.mailRead === undefined ? listed : new Set([...k.mailRead].filter((h) => listed.has(h)));
    }
  }
}

/** One pass of the admission fold over [envelopes] less [excluded]: the keys, and the envelopes that admitted or revoked one. */
async function admit(envelopes: Stored[], excluded: Set<string>): Promise<{ keys: Keys; applied: Stored[] }> {
  const a: Admission = { keys: new Map(), dinners: new Map(), joins: new Map() };
  const revokes: Stored[] = [];
  const applied: Stored[] = [];
  for (const s of envelopes) {
    const b = obj(s.body);
    if (b === undefined || excluded.has(s.hash)) continue;
    switch (s.envelope.kind) {
      case 'dinner': {
        const host = str(b['host']);
        if (host === undefined) break;
        if (!a.keys.has(s.envelope.author)) a.keys.set(s.envelope.author, { identity: host, role: 'device', revoked: false });
        a.dinners.set(s.hash, { host, author: s.envelope.author });
        applied.push(s);
        break;
      }
      case 'join': {
        const id = str(b['identity_key']);
        const d = str(b['device_key']);
        const dinner = str(b['dinner']);
        if (id === undefined || d === undefined) break;
        a.keys.set(d, { identity: id, role: 'device', revoked: false });
        if (dinner !== undefined && !a.joins.has(id)) a.joins.set(id, { dinner, at: s.envelope.created_at });
        break;
      }
      case 'device': {
        const id = str(b['identity_key']);
        const k = str(b['key']);
        const role = str(b['role']);
        if (id === undefined || k === undefined || (role !== 'device' && role !== 'mail')) break;
        if (!(await verifyDevice(b as unknown as Parameters<typeof verifyDevice>[0]))) break;
        a.keys.set(k, { identity: id, role, revoked: false });
        applied.push(s);
        break;
      }
      case 'revoke':
        revokes.push(s);
        break;
    }
  }
  for (const s of revokes.sort((x, y) =>
    foldOrder({ at: x.envelope.created_at, hash: x.hash }, { at: y.envelope.created_at, hash: y.hash })
  )) {
    const r = await revokeStops(a, s);
    if (r === undefined) continue;
    recordCutoffs(r);
    applied.push(s);
  }
  return { keys: a.keys, applied };
}

/**
 * Which identity each admitted key speaks for, and each revoked key's cutoff, as the node's fold
 * reads them (node/core/fold.ml, run): an envelope past its author's cutoff that admitted or revoked
 * a key is left out and the fold run again, since it may have admitted keys of its own. The first
 * dinner, the circle root, is never left out.
 */
async function identities(envelopes: Stored[]): Promise<Keys> {
  const root = envelopes.find((s) => s.envelope.kind === 'dinner')?.hash;
  const excluded = new Set<string>();
  for (;;) {
    const { keys, applied } = await admit(envelopes, excluded);
    const past = applied.filter((s) => s.hash !== root && pastCutoff(keys, s));
    if (past.length === 0) return keys;
    for (const s of past) excluded.add(s.hash);
  }
}

/** Whether [s] speaks for [identity]: written by a key of theirs in force for it. */
const by =
  (keys: Keys, identity: string) =>
  (s: Stored): boolean =>
    speaker(keys, s) === identity;

interface Card {
  key: string;
  name?: string;
  agentName?: string;
}

/** Each identity's newest card a key of theirs wrote: its encryption key and its names. */
function cards(keys: Keys, envelopes: Stored[]): Map<string, Card> {
  const out = new Map<string, Card & { at: string }>();
  for (const s of envelopes) {
    if (s.envelope.kind !== 'card') continue;
    const id = speaker(keys, s);
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
  // A choice's deadline is in the protocol's Z form or the item is unreadable, as on the node (DIG-555).
  if (kind === 'choice' && p['deadline'] != null && !(deadline !== undefined && isZForm(deadline))) return undefined;
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

/**
 * The member's decisions, by the hash of the item each names, in the follow-up order (signed time
 * then hash, as the node's Store.Items.picks orders them), whatever order the relay held them in.
 * One signed at a time not in the Z form counts for nothing, as on the node (DIG-99), so it is left out.
 */
async function decisions(
  e: Enrollment,
  mine: (s: Stored) => boolean,
  envelopes: Stored[]
): Promise<Map<string, { option: string; at: string; hash: string }[]>> {
  const out = new Map<string, { option: string; at: string; hash: string }[]>();
  for (const s of envelopes) {
    if (s.envelope.kind !== 'decision' || !mine(s) || !isZForm(s.envelope.created_at)) continue;
    const b = obj(s.body);
    const named = str(b?.['item']);
    const option = str((await open(e, b?.['sealed']))?.['option']);
    if (named === undefined || option === undefined) continue;
    out.set(named, [...(out.get(named) ?? []), { option, at: s.envelope.created_at, hash: s.hash }]);
  }
  for (const l of out.values()) l.sort(followUpOrder);
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
  keys: Keys,
  card: Map<string, Card>,
  envelopes: Stored[],
  questions: Map<string, PhoneItem>
): Promise<Map<string, PhoneAnswer[]>> {
  const out = new Map<string, PhoneAnswer[]>();
  for (const s of envelopes) {
    if (s.envelope.kind !== 'item_answer') continue;
    const author = speaker(keys, s);
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
  for (const l of out.values()) l.sort((a, b) => followUpOrder({ at: a.created_at, hash: a.hash }, { at: b.created_at, hash: b.hash }));
  return out;
}

/**
 * The close that stands on each item: the newest `person` one by its author, else the newest `agent`
 * one. A close or reopen signed at a time not in the Z form counts for nothing, as on the node (DIG-99).
 */
async function closes(e: Enrollment, keys: Keys, envelopes: Stored[], authors: Map<string, string>): Promise<Map<string, boolean>> {
  const read = new Map<string, { closed: boolean; person: boolean; at: string; hash: string }[]>();
  for (const s of envelopes) {
    if (s.envelope.kind !== 'item_close' || !isZForm(s.envelope.created_at)) continue;
    const f = await follow(e, s);
    const item = f?.item;
    if (item === undefined || authors.get(item) === undefined || speaker(keys, s) !== authors.get(item)) continue;
    const p = f?.fields;
    if (typeof p?.['closed'] !== 'boolean') continue;
    read.set(item, [
      ...(read.get(item) ?? []),
      { closed: p['closed'], person: str(p['voice']) === 'person', at: s.envelope.created_at, hash: s.hash }
    ]);
  }
  const out = new Map<string, boolean>();
  for (const [item, cs] of read) {
    // In the fold's order, the same as the node's Item.standing.
    const person = cs.filter((c) => c.person).sort(foldOrder);
    const stands = person.at(-1) ?? [...cs].sort(foldOrder).at(-1);
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
  const keys = await identities(envelopes);
  const card = cards(keys, envelopes);
  const out: PhoneItem[] = [];
  for (const s of envelopes) {
    const author = speaker(keys, s);
    if (author === undefined) continue;
    const read = s.envelope.kind === 'item' ? await readItem(e, s, author, card) : undefined;
    if (read !== undefined) out.push(read);
  }
  const picks = await decisions(e, by(keys, e.identity), envelopes);
  const closed = await closes(e, keys, envelopes, new Map(out.map((i) => [i.hash, i.author])));
  const said = await answers(e, keys, card, envelopes, new Map(out.filter((i) => i.kind === 'question').map((i) => [i.hash, i])));
  for (const i of out) {
    if (i.kind === 'question') {
      i.answers = said.get(i.hash) ?? [];
      i.answered = i.answers.some((a) => a.author === e.identity);
      // Only an answer signed before the lapse counts; a later one is listed and reopens nothing (DIG-544).
      // The clock applies only with no close or reopen by the author standing, as on the node.
      // An answer whose signed time is not in the Z form counts for nothing, as on the node (DIG-91); it is still listed.
      const lapse = Date.parse(i.created_at) + QUESTION_LAPSE_MS;
      const inTime = (a: PhoneAnswer) => a.author !== i.author && isZForm(a.created_at) && Date.parse(a.created_at) < lapse;
      if (!closed.has(i.hash) && !i.answers.some(inTime)) {
        i.lapses = new Date(lapse).toISOString();
      }
    }
    // The first pick of an option the item offers counts, before a choice's deadline; a notice takes only an Acknowledge.
    const first = (picks.get(i.hash) ?? []).find((d) =>
      i.kind === 'notice'
        ? d.option === ACKNOWLEDGE
        : i.options.some((o) => o.id === d.option) && (i.deadline === undefined || Date.parse(d.at) < Date.parse(i.deadline))
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
  const mine = by(await identities(envelopes), e.identity);
  const summaries = envelopes
    .filter((s) => s.envelope.kind === 'summary' && mine(s))
    .sort((a, b) => b.envelope.created_at.localeCompare(a.envelope.created_at));
  if (str(obj(summaries[0]?.body)?.['stage']) !== 'paused') return undefined;
  const note = summaries.find((s) => str(obj(s.body)?.['status']) === 'paused');
  return (note ?? summaries[0])?.envelope.created_at;
}

/** What the phone runs the deny layer with: the member's own entries, and the names no name entry trips on. */
export interface DenyLayer {
  entries: DenyEntry[];
  /** The circle's member and agent names, from every member's newest card. */
  allowed: string[];
}

/**
 * The deny layer as the member's node shared it (docs/protocol.md, The phone): the entries of the
 * newest `deny_list` a key of the member wrote, opened with their key, and the circle's names.
 * Undefined until their node has written one, so the phone never checks against a list it lacks.
 */
export async function denyLayer(e: Enrollment, all: Stored[]): Promise<DenyLayer | undefined> {
  const envelopes = await verified(all);
  const keys = await identities(envelopes);
  const mine = by(keys, e.identity);
  const lists = envelopes
    .filter((s) => s.envelope.kind === 'deny_list' && mine(s))
    .sort((a, b) => b.envelope.created_at.localeCompare(a.envelope.created_at) || b.hash.localeCompare(a.hash));
  for (const s of lists) {
    const p = await open(e, obj(s.body)?.['sealed']);
    if (p === undefined || !Array.isArray(p['entries'])) continue;
    const entries = (p['entries'] as Json[]).flatMap((x) => {
      const kind = str(obj(x)?.['kind']);
      const value = str(obj(x)?.['value']);
      return kind === undefined || value === undefined ? [] : [{ kind, value }];
    });
    const allowed = [...cards(keys, envelopes).values()].flatMap((c) => [c.name, c.agentName].filter((n) => n !== undefined));
    return { entries, allowed };
  }
  return undefined;
}

/** Where the phone's own chain ends: the next seq and the hash before it. */
export function chainEnd(keys: PhoneKeys, envelopes: Stored[]): { seq: number; prev?: string } {
  const me = keyTextEd25519(keys.ed25519);
  let last: Stored | undefined;
  for (const s of envelopes) if (s.envelope.author === me && (last === undefined || s.envelope.seq > last.envelope.seq)) last = s;
  return last === undefined ? { seq: 1 } : { seq: last.envelope.seq + 1, prev: last.hash };
}
