// D1 access: the log, the derived state, and the fold replayed from the log. The shared fold
// (conformance/src/fold.ts) keeps its state in memory and exposes no way to load it, so the relay
// rebuilds it per append from the circle-state envelopes, which are few (one per dinner, join,
// device and revoke), and keeps its output in admitted_keys for the reads and the request checks.
import type { Json } from "../../conformance/src/encoding.ts";
import { CIRCLE_STATE_KINDS, type Envelope, type StoredEnvelope } from "../../conformance/src/envelope.ts";
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
 * configuration and must match it on every request: a database that served another circle is
 * refused. Two small statements per request; not cached, so a database swapped under a running
 * isolate (the tests do that) is seen at once.
 */
export async function ensureCircle(db: D1Database, root: string): Promise<void> {
  await db.prepare("INSERT OR IGNORE INTO circle (id, root, epoch) VALUES (1, ?, 0)").bind(root).run();
  const row = await db.prepare("SELECT root FROM circle WHERE id = 1").first<{ root: string }>();
  if (row?.root !== root) throw new ConfigError(`this database serves circle ${row?.root ?? "(none)"}, not CIRCLE_ROOT ${root}`);
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
  /** One more envelope to fold at its position: the target of a retract, so the retract rule can see its author. */
  include?: string;
  /** Fold only the envelopes below this relay_id: the log as it stood when an append chose that position. */
  before?: number;
  /**
   * The release signer set the relay starts from: the fold judges admissions after the circle's
   * cutover (docs/protocol.md, The admission fold). Omitted, it folds every dinner by its guests'
   * invite keys alone, which a replay of an accepted log reaches either way.
   */
  signers?: string[];
}

const CIRCLE_STATE_IN = CIRCLE_STATE_KINDS.map((k) => `'${k}'`).join(", ");

/**
 * The circle-state envelopes below a relay_id, read through envelopes_kind_relay_id. INDEXED BY
 * pins the index: with the relay_id bound alone SQLite prefers walking the primary key, which reads
 * every row of the log, bodies included, and D1 bills each one. An OR on hash in the same statement
 * has the same effect, so the retract target is its own statement. DIG-206
 */
export const CIRCLE_STATE_SQL = `SELECT ${ENVELOPE_COLUMNS} FROM envelopes INDEXED BY envelopes_kind_relay_id WHERE kind IN (${CIRCLE_STATE_IN}) AND relay_id < ?`;
export const INCLUDED_SQL = `SELECT ${ENVELOPE_COLUMNS} FROM envelopes WHERE hash = ? AND relay_id < ?`;

/** The rows foldLog replays, in relay order: one batch, so both statements read the same log. */
async function logRows(db: D1Database, scope: FoldScope): Promise<EnvelopeRow[]> {
  const below = scope.before ?? Number.MAX_SAFE_INTEGER;
  if (scope.all) {
    const { results } = await db.prepare(`SELECT ${ENVELOPE_COLUMNS} FROM envelopes WHERE relay_id < ? ORDER BY relay_id`).bind(below).all<EnvelopeRow>();
    return results;
  }
  const statements = [db.prepare(CIRCLE_STATE_SQL).bind(below)];
  if (scope.include !== undefined) statements.push(db.prepare(INCLUDED_SQL).bind(scope.include, below));
  const [state, included] = await db.batch<EnvelopeRow>(statements);
  if (state === undefined) throw new Error("the circle-state read returned no result");
  const rows = state.results;
  const extra = included?.results[0];
  if (extra !== undefined && !rows.some((row) => row.relay_id === extra.relay_id)) rows.push(extra);
  return rows.sort((a, b) => a.relay_id - b.relay_id);
}

/**
 * The fold replayed from the log in relay order. Every stored envelope was accepted by the fold when
 * it arrived, with its relay_id as position and its judged_at, or else its received_at, as the clock,
 * so replaying them with the same inputs reaches the same state; one that does not replay is a corrupt log, not a refusal.
 */
export async function foldLog(db: D1Database, root: string, scope: FoldScope = {}): Promise<Fold> {
  const rows = await logRows(db, scope);
  const fold = new Fold(root, scope.signers === undefined ? {} : { admission: { cutover: await admissionCutover(db), signers: scope.signers } });
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
