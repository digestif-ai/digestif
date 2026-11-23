// D1 access: the log, the derived state, and the fold replayed from the log. The shared fold
// (conformance/src/fold.ts) keeps its state in memory and exposes no way to load it, so the relay
// replays it from the circle-state envelopes and keeps its output in admitted_keys for the reads
// and the request checks. That set grows with members, devices, dinners, releases and prompt
// changes, so an isolate keeps the fold it last built (foldCache) and an append folds only the
// circle-state envelopes committed since: one read of the ids, no replay (DIG-217).
import type { Json } from "../../conformance/src/encoding.ts";
import { CIRCLE_STATE_KINDS, isCircleState, type Envelope, type StoredEnvelope } from "../../conformance/src/envelope.ts";
import { Fold, type KeyState } from "../../conformance/src/fold.ts";
import { ConfigError } from "./env.ts";

export interface EnvelopeRow {
  relay_id: number;
  hash: string;
  author: string;
  seq: number;
  kind: string;
  epoch: number;
  created_at: string;
  received_at: string;
  /** The clock the fold judged the envelope at when it is not received_at: a join a member pushed, judged at its created_at. */
  judged_at: string | null;
  envelope: string;
  body: string | null;
}

export interface KeyRow {
  key: string;
  role: string;
  identity: string;
  admitted_at: number;
  join_epoch: number;
  revoked_at: number | null;
  after_seq: number | null;
  mail_read: string | null;
}

export const ENVELOPE_COLUMNS = "relay_id, hash, author, seq, kind, epoch, created_at, received_at, judged_at, envelope, body";
export const KEY_COLUMNS = "key, role, identity, admitted_at, join_epoch, revoked_at, after_seq, mail_read";

export function storedOf(row: EnvelopeRow): StoredEnvelope {
  return {
    relay_id: row.relay_id,
    hash: row.hash,
    envelope: JSON.parse(row.envelope) as Envelope,
    ...(row.body === null ? {} : { body: JSON.parse(row.body) as Json }),
    received_at: row.received_at,
  };
}

export function keyStateOf(row: KeyRow): KeyState {
  return {
    key: row.key,
    role: row.role as KeyState["role"],
    identity: row.identity,
    admitted_at: row.admitted_at,
    join_epoch: row.join_epoch,
    ...(row.revoked_at === null ? {} : { revoked_at: row.revoked_at }),
    ...(row.after_seq === null ? {} : { after_seq: row.after_seq }),
    ...(row.mail_read === null ? {} : { mail_read: new Set(JSON.parse(row.mail_read) as string[]) }),
  };
}

/** The bind values of a key row, in KEY_COLUMNS order. */
export function keyValues(state: KeyState): [string, string, string, number, number, number | null, number | null, string | null] {
  return [
    state.key,
    state.role,
    state.identity,
    state.admitted_at,
    state.join_epoch,
    state.revoked_at ?? null,
    state.after_seq ?? null,
    state.mail_read === undefined ? null : JSON.stringify([...state.mail_read].sort()),
  ];
}

/** A KeyState as plain JSON, mail_read as a sorted list: what the tests compare and what nothing serves. */
export function keyJson(state: KeyState): Json {
  return {
    key: state.key,
    role: state.role,
    identity: state.identity,
    admitted_at: state.admitted_at,
    join_epoch: state.join_epoch,
    ...(state.revoked_at === undefined ? {} : { revoked_at: state.revoked_at }),
    ...(state.after_seq === undefined ? {} : { after_seq: state.after_seq }),
    ...(state.mail_read === undefined ? {} : { mail_read: [...state.mail_read].sort() }),
  };
}

/**
 * The circle row names the root this database serves. It is written on first use from the Worker's
 * configuration and must match it: a database that served another circle is refused. An isolate
 * checks it once per database binding and root (one read, two statements on first use); an append
 * reads the row again in its check batch (checkedRoot), so a row cleared and re-rooted under a
 * running isolate refuses that isolate's writes. DIG-234
 */
const circleChecked = new WeakMap<D1Database, string>();

export async function ensureCircle(db: D1Database, root: string): Promise<void> {
  if (circleChecked.get(db) === root) return;
  let row = await db.prepare("SELECT root FROM circle WHERE id = 1").first<{ root: string }>();
  if (row === null) {
    const [, read] = await db.batch<{ root: string }>([
      db.prepare("INSERT OR IGNORE INTO circle (id, root, epoch) VALUES (1, ?, 0)").bind(root),
      db.prepare("SELECT root FROM circle WHERE id = 1"),
    ]);
    row = read?.results[0] ?? null;
  }
  checkedRoot(db, root, row?.root);
}

/** Refuses a database whose circle row names another root, and forgets the isolate's check of it. */
export function checkedRoot(db: D1Database, root: string, held: string | undefined): void {
  if (held === root) {
    circleChecked.set(db, root);
    return;
  }
  circleChecked.delete(db);
  throw new ConfigError(`this database serves circle ${held ?? "(none)"}, not ${root}`);
}

export async function circleEpoch(db: D1Database): Promise<number> {
  const row = await db.prepare("SELECT epoch FROM circle WHERE id = 1").first<{ epoch: number }>();
  return row?.epoch ?? 0;
}

/** The relay_id at or before which a dinner admits by its invite keys alone (migrations/0004_admission_cutover.sql). */
export async function admissionCutover(db: D1Database): Promise<number> {
  const row = await db.prepare("SELECT admission_cutover FROM circle WHERE id = 1").first<{ admission_cutover: number }>();
  return row?.admission_cutover ?? 0;
}

export async function loadKey(db: D1Database, key: string): Promise<KeyState | undefined> {
  const row = await db.prepare(`SELECT ${KEY_COLUMNS} FROM admitted_keys WHERE key = ?`).bind(key).first<KeyRow>();
  return row === null ? undefined : keyStateOf(row);
}

/** Every key the fold has seen, sorted by key as GET /v0/circle reports them. */
export async function loadKeys(db: D1Database): Promise<KeyState[]> {
  const { results } = await db.prepare(`SELECT ${KEY_COLUMNS} FROM admitted_keys ORDER BY key`).all<KeyRow>();
  return results.map(keyStateOf);
}

export async function loadEnvelope(db: D1Database, hash: string): Promise<EnvelopeRow | undefined> {
  const row = await db.prepare(`SELECT ${ENVELOPE_COLUMNS} FROM envelopes WHERE hash = ?`).bind(hash).first<EnvelopeRow>();
  return row ?? undefined;
}

export interface FoldScope {
  /** Fold every envelope rather than the circle-state ones: the full refold the tests compare against. */
  all?: boolean;
  /** Fold only the envelopes below this relay_id: the log as it stood when an append chose that position. */
  before?: number;
  /**
   * The release signer set the relay starts from: the fold judges admissions after the circle's
   * cutover (docs/protocol.md, The admission fold). Omitted, it folds every dinner by its guests'
   * invite keys alone, which a replay of an accepted log reaches either way.
   */
  signers?: string[];
  /**
   * The cutover and the circle-state ids below `before`, already read in the caller's own batch: the
   * circle-state fold then reads only the envelopes its kept fold has not folded, if any.
   */
  read?: { cutover: number; ids: FoldedIdRow[] };
}

const CIRCLE_STATE_IN = CIRCLE_STATE_KINDS.map((k) => `'${k}'`).join(", ");

/**
 * The circle-state envelopes below a relay_id, read through envelopes_kind_relay_id. INDEXED BY
 * pins the index: with the relay_id bound alone SQLite prefers walking the primary key, which reads
 * every row of the log, bodies included, and D1 bills each one. DIG-206
 */
export const CIRCLE_STATE_SQL = `SELECT ${ENVELOPE_COLUMNS} FROM envelopes INDEXED BY envelopes_kind_relay_id WHERE kind IN (${CIRCLE_STATE_IN}) AND relay_id < ?`;

/**
 * What a retract append reads of its target, by the hash's unique index: the kind the retract rule
 * refuses a circle-state target by, and the author the fold judges the retract against. DIG-241
 */
export const RETRACT_TARGET_SQL = "SELECT kind, author FROM envelopes WHERE hash = ?";

/** Every envelope below `before`, in relay order: the full refold. */
async function allRows(db: D1Database, below: number): Promise<EnvelopeRow[]> {
  const { results } = await db.prepare(`SELECT ${ENVELOPE_COLUMNS} FROM envelopes WHERE relay_id < ? ORDER BY relay_id`).bind(below).all<EnvelopeRow>();
  return results;
}

/**
 * The fold replayed from the log in relay order. Every stored envelope was accepted by the fold when
 * it arrived, with its relay_id as position and its judged_at, or else its received_at, as the clock,
 * so replaying them with the same inputs reaches the same state; one that does not replay is a corrupt log, not a refusal.
 *
 * The circle-state fold (no `all`) starts from the isolate's kept fold when the log still begins
 * with exactly the envelopes it folded, and is a copy the caller may apply to.
 */
export async function foldLog(db: D1Database, root: string, scope: FoldScope = {}): Promise<Fold> {
  const below = scope.before ?? Number.MAX_SAFE_INTEGER;
  if (scope.all) return replay(newFold(root, scope, await admissionCutover(db)), await allRows(db, below));
  return foldCircleState(db, root, scope, below);
}

/** One circle-state envelope as the kept fold names it: position, hash and the clock it was judged at. */
type FoldedId = string;

/** What CIRCLE_STATE_IDS_SQL reads of one circle-state envelope. */
export interface FoldedIdRow {
  relay_id: number;
  hash: string;
  received_at: string;
  judged_at: string | null;
}

function foldedId(row: FoldedIdRow): FoldedId {
  return `${row.relay_id} ${row.hash} ${row.judged_at ?? row.received_at}`;
}

interface KeptFold {
  /** The root, cutover and signer set the fold was built with. */
  config: string;
  /** The circle-state envelopes it folded, in relay order. */
  ids: FoldedId[];
  fold: Fold;
}

/**
 * The isolate's last circle-state fold of each circle, by root. One is trusted only for a log whose
 * circle-state envelopes begin with exactly its ids, hashes and clocks included, so a database
 * swapped under the isolate, or written by another isolate, is refolded or extended rather than
 * misread. An isolate keeps the folds of the circles it served last, a few at a time.
 */
const foldCache = new Map<string, KeptFold>();
const KEPT_FOLDS = 8;

function keep(root: string, kept: KeptFold): void {
  foldCache.delete(root);
  foldCache.set(root, kept);
  for (const oldest of foldCache.keys()) {
    if (foldCache.size <= KEPT_FOLDS) break;
    foldCache.delete(oldest);
  }
}

/** Drops every kept fold, as a fresh isolate starts: the tests' way to fold from a log another isolate wrote. */
export function forgetKeptFold(): void {
  foldCache.clear();
}

/** The folds foldLog handed out, with the ids each was built from, so a committed append can keep its fold. */
const handedOut = new WeakMap<Fold, { root: string; config: string; ids: FoldedId[] }>();

/** The ids of the circle-state envelopes below a relay_id, through the same pinned index as CIRCLE_STATE_SQL. */
export const CIRCLE_STATE_IDS_SQL = `SELECT relay_id, hash, received_at, judged_at FROM envelopes INDEXED BY envelopes_kind_relay_id WHERE kind IN (${CIRCLE_STATE_IN}) AND relay_id < ?`;

async function foldCircleState(db: D1Database, root: string, scope: FoldScope, below: number): Promise<Fold> {
  const cutover = scope.read?.cutover ?? (await admissionCutover(db));
  const config = JSON.stringify({ root, cutover, signers: scope.signers ?? null });
  const results = [...(scope.read?.ids ?? (await db.prepare(CIRCLE_STATE_IDS_SQL).bind(below).all<FoldedIdRow>()).results)];
  results.sort((a, b) => a.relay_id - b.relay_id);
  const ids = results.map(foldedId);
  const kept = foldCache.get(root);
  const extendsKept = kept !== undefined && kept.config === config && kept.ids.length <= ids.length && kept.ids.every((id, i) => ids[i] === id);
  let fold: Fold;
  if (extendsKept) {
    fold = kept.fold.clone();
    const last = results[kept.ids.length - 1]?.relay_id ?? 0;
    if (kept.ids.length < ids.length) replay(fold, await circleStateRows(db, below, last));
  } else {
    fold = replay(newFold(root, scope, cutover), await circleStateRows(db, below));
  }
  // A fold of a shorter prefix of the same log (an append chose an earlier position) leaves the kept one.
  const shorterPrefix = kept !== undefined && kept.config === config && kept.ids.length > ids.length && ids.every((id, i) => kept.ids[i] === id);
  if (!shorterPrefix && (!extendsKept || kept.ids.length < ids.length)) keep(root, { config, ids, fold: fold.clone() });
  handedOut.set(fold, { root, config, ids });
  return fold;
}

/** The circle-state envelopes below `below` (and above `after`, when given), in relay order. */
async function circleStateRows(db: D1Database, below: number, after?: number): Promise<EnvelopeRow[]> {
  const statement = after === undefined ? db.prepare(CIRCLE_STATE_SQL).bind(below) : db.prepare(`${CIRCLE_STATE_SQL} AND relay_id > ?`).bind(below, after);
  const { results } = await statement.all<EnvelopeRow>();
  return results.sort((a, b) => a.relay_id - b.relay_id);
}

/**
 * After an append's batch committed: the fold foldLog handed it, with the envelope applied, is the
 * circle-state fold of the log through that envelope, kept for the next append. A content envelope
 * leaves the circle-state fold as it was.
 */
export function keepFold(fold: Fold, row: EnvelopeRow): void {
  const origin = handedOut.get(fold);
  if (origin === undefined || !isCircleState(row.kind)) return;
  handedOut.delete(fold);
  keep(origin.root, { config: origin.config, ids: [...origin.ids, foldedId(row)], fold: fold.clone() });
}

function newFold(root: string, scope: FoldScope, cutover: number): Fold {
  return new Fold(root, scope.signers === undefined ? {} : { admission: { cutover, signers: scope.signers } });
}

function replay(fold: Fold, rows: EnvelopeRow[]): Fold {
  for (const row of rows) {
    const error = fold.apply({
      hash: row.hash,
      envelope: JSON.parse(row.envelope) as Envelope,
      body: row.body === null ? undefined : (JSON.parse(row.body) as Json),
      position: row.relay_id,
      now: new Date(row.judged_at ?? row.received_at),
      stored: true,
    });
    if (error !== null) throw new Error(`the log does not refold: relay_id ${row.relay_id} (${row.kind}) is ${error}`);
  }
  return fold;
}

function sameKey(a: KeyState, b: KeyState): boolean {
  return JSON.stringify(keyJson(a)) === JSON.stringify(keyJson(b));
}

/** A copy of the fold's keys, so the keys an apply changes can be told from the rest. */
export function snapshotKeys(fold: Fold): Map<string, KeyState> {
  return new Map([...fold.keys].map(([key, state]) => [key, { ...state, ...(state.mail_read === undefined ? {} : { mail_read: new Set(state.mail_read) }) }]));
}

/** The keys that differ from the snapshot: new ones and changed ones. The fold never drops a key. */
export function changedKeys(before: Map<string, KeyState>, fold: Fold): KeyState[] {
  const changed: KeyState[] = [];
  for (const state of fold.keys.values()) {
    const was = before.get(state.key);
    if (was === undefined || !sameKey(was, state)) changed.push(state);
  }
  return changed;
}
