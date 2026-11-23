// The home circle's move from the relay's D1 into its own store (docs/protocol.md, Hosted circles,
// "Moving the home circle's log"), run by the store's alarm in bounded, resumable steps so no
// request's limits and no day's write allowance are crossed.
//
// - copying: each alarm copies the next batch of envelopes by relay_id and records the last copied
//   id in the same transaction; a step cut off rolls back whole, and a row already held is skipped
//   by its relay_id. At most rows_per_day rows a day; past that the alarm waits for the next UTC day.
//   D1 serves the circle the whole time (store `moving`) and the copy chases its tail.
// - draining: once a batch comes back short, the registry row goes `draining`. From then on D1's
//   triggers (migrations/0006_hosted_circles.sql) abort every append, mailed link and mailed digest
//   that would land in its tables, and the relay answers those 503 moving; reads keep answering
//   from D1. The alarm copies what arrived before the switch, then the circle's other tables, and
//   sets the row `object`: every route answers from the store from then on.
//
// Every row keeps its relay_id, received_at and judged_at, so every node's cursor and the admission
// cutover keep their positions, and the next append takes the next relay_id.
import { isoTime } from "../../conformance/src/encoding.ts";
import { ENVELOPE_COLUMNS, type EnvelopeRow } from "./db.ts";

/** Rows one alarm copies at most. */
export const MOVE_BATCH = 500;

/** The move's progress, kept in the store beside the circle's tables. */
const STATE_TABLE =
  "CREATE TABLE IF NOT EXISTS move_state (id INTEGER PRIMARY KEY CHECK (id = 1), root TEXT NOT NULL, phase TEXT NOT NULL, " +
  "last_relay_id INTEGER NOT NULL, day TEXT NOT NULL, rows_today INTEGER NOT NULL, rows_per_day INTEGER NOT NULL, batch INTEGER NOT NULL)";

export interface MoveState {
  root: string;
  phase: "copying" | "draining" | "done";
  last_relay_id: number;
  day: string;
  rows_today: number;
  rows_per_day: number;
  batch: number;
}

export function moveState(storage: DurableObjectStorage): MoveState | undefined {
  storage.sql.exec(STATE_TABLE);
  return storage.sql.exec<Record<string, SqlStorageValue>>("SELECT root, phase, last_relay_id, day, rows_today, rows_per_day, batch FROM move_state WHERE id = 1").toArray()[0] as unknown as
    | MoveState
    | undefined;
}

function save(storage: DurableObjectStorage, state: MoveState): void {
  storage.sql.exec(
    "INSERT OR REPLACE INTO move_state (id, root, phase, last_relay_id, day, rows_today, rows_per_day, batch) VALUES (1, ?, ?, ?, ?, ?, ?, ?)",
    state.root,
    state.phase,
    state.last_relay_id,
    state.day,
    state.rows_today,
    state.rows_per_day,
    state.batch,
  );
}

/**
 * Begins the move of [root] into this store, or takes the newer pace for one already under way, and
 * makes sure an alarm will drive it. A move that is done stays done.
 */
export async function beginMove(storage: DurableObjectStorage, root: string, rowsPerDay: number, batch: number, now: Date): Promise<void> {
  const state = moveState(storage);
  if (state?.phase === "done") return;
  save(storage, {
    root,
    phase: state?.phase ?? "copying",
    last_relay_id: state?.last_relay_id ?? 0,
    day: state?.day ?? isoTime(now).slice(0, 10),
    rows_today: state?.rows_today ?? 0,
    rows_per_day: rowsPerDay,
    batch,
  });
  if ((await storage.getAlarm()) === null) await storage.setAlarm(now.getTime());
}

/** Midnight UTC after [now]: when a day's copy allowance starts again. */
function nextDay(now: Date): number {
  return Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1);
}

/** The envelopes after a relay_id in D1, in relay order. */
async function envelopesAfter(d1: D1Database, after: number, limit: number): Promise<EnvelopeRow[]> {
  const { results } = await d1.prepare(`SELECT ${ENVELOPE_COLUMNS} FROM envelopes WHERE relay_id > ? ORDER BY relay_id LIMIT ?`).bind(after, limit).all<EnvelopeRow>();
  return results;
}

/** Writes copied envelopes and the new cursor in one transaction; a row already held is skipped. */
function copyEnvelopes(storage: DurableObjectStorage, state: MoveState, rows: EnvelopeRow[]): void {
  storage.transactionSync(() => {
    for (const r of rows) {
      storage.sql.exec(
        "INSERT OR IGNORE INTO envelopes (relay_id, hash, author, seq, kind, epoch, created_at, received_at, judged_at, envelope, body) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        r.relay_id,
        r.hash,
        r.author,
        r.seq,
        r.kind,
        r.epoch,
        r.created_at,
        r.received_at,
        r.judged_at,
        r.envelope,
        r.body,
      );
    }
    const last = rows[rows.length - 1];
    if (last !== undefined) state.last_relay_id = last.relay_id;
    state.rows_today += rows.length;
    save(storage, state);
  });
}

/**
 * One alarm's step of the move. Answers what it did, for the tests: `waiting` when the day's
 * allowance is spent, `copied` after a batch, `draining` when it switched the circle to draining,
 * `done` once the store serves it, `idle` when there is no move.
 */
export async function moveStep(storage: DurableObjectStorage, d1: D1Database, now: Date): Promise<"idle" | "waiting" | "copied" | "draining" | "done"> {
  const state = moveState(storage);
  if (state === undefined || state.phase === "done") return "idle";
  const today = isoTime(now).slice(0, 10);
  if (state.day !== today) {
    state.day = today;
    state.rows_today = 0;
    save(storage, state);
  }
  if (state.phase === "copying") {
    const room = state.rows_per_day - state.rows_today;
    if (room <= 0) {
      await storage.setAlarm(nextDay(now));
      return "waiting";
    }
    const take = Math.min(state.batch, room);
    const rows = await envelopesAfter(d1, state.last_relay_id, take);
    copyEnvelopes(storage, state, rows);
    if (rows.length === take) {
      await storage.setAlarm(now.getTime());
      return "copied";
    }
    // Caught up: from here on D1 takes no more writes for this circle.
    await d1.prepare("UPDATE hosted_circles SET store = 'draining' WHERE root = ? AND store IN ('d1', 'moving')").bind(state.root).run();
    state.phase = "draining";
    save(storage, state);
    await storage.setAlarm(now.getTime());
    return "draining";
  }
  // draining: the tail that arrived before the switch, then the rest of the circle, then the cutover.
  const tail = await envelopesAfter(d1, state.last_relay_id, state.batch);
  if (tail.length > 0) {
    copyEnvelopes(storage, state, tail);
    await storage.setAlarm(now.getTime());
    return "copied";
  }
  await copyTables(storage, d1, state.root, now);
  await d1.batch([
    d1.prepare("INSERT OR IGNORE INTO invite_index (key, root) SELECT key, ? FROM invites WHERE spent = 0").bind(state.root),
    d1.prepare("UPDATE hosted_circles SET store = 'object' WHERE root = ? AND store = 'draining'").bind(state.root),
  ]);
  state.phase = "done";
  save(storage, state);
  return "done";
}

/** A table of the circle's own, the columns copied, and which rows: only what still matters. */
interface Copied {
  table: string;
  columns: string;
  where?: string;
  binds?: (now: Date) => unknown[];
}

/**
 * The circle's tables besides its log. The fold's output (admitted_keys, the circle row's epoch and
 * cutover) and the invites are D1's as the log stands, which no write changes any more; nonces and
 * daily counts only while they still count; mail leases are left to expire.
 */
const TABLES: Copied[] = [
  { table: "admitted_keys", columns: "key, role, identity, admitted_at, join_epoch, revoked_at, after_seq, mail_read" },
  { table: "invites", columns: "key, dinner, expires_at, spent" },
  { table: "mailed_digests", columns: "digest, sent_at" },
  { table: "links", columns: "id, digest, ask, expires_at, used_at" },
  { table: "daily_appends", columns: "author, day, count", where: "day >= ?", binds: (now) => [isoTime(now).slice(0, 10)] },
  { table: "nonces", columns: "key, nonce, expires_at", where: "expires_at >= ?", binds: (now) => [now.getTime()] },
];

async function copyTables(storage: DurableObjectStorage, d1: D1Database, root: string, now: Date): Promise<void> {
  const circle = await d1.prepare("SELECT root, epoch, admission_cutover FROM circle WHERE id = 1").first<{ root: string; epoch: number; admission_cutover: number }>();
  const rows: Array<{ table: string; columns: string; values: unknown[][] }> = [];
  for (const copied of TABLES) {
    const where = copied.where === undefined ? "" : ` WHERE ${copied.where}`;
    const values = await d1
      .prepare(`SELECT ${copied.columns} FROM ${copied.table}${where}`)
      .bind(...(copied.binds?.(now) ?? []))
      .raw<unknown[]>();
    rows.push({ table: copied.table, columns: copied.columns, values });
  }
  storage.transactionSync(() => {
    if (circle !== null && circle.root === root) {
      storage.sql.exec(
        "INSERT INTO circle (id, root, epoch, admission_cutover) VALUES (1, ?, ?, ?) ON CONFLICT (id) DO UPDATE SET epoch = excluded.epoch, admission_cutover = excluded.admission_cutover",
        root,
        circle.epoch,
        circle.admission_cutover,
      );
    }
    for (const { table, columns, values } of rows) {
      const marks = columns.split(",").map(() => "?").join(", ");
      for (const value of values) storage.sql.exec(`INSERT OR REPLACE INTO ${table} (${columns}) VALUES (${marks})`, ...(value as SqlStorageValue[]));
    }
    // A retract that arrived while the copy ran dropped a body this store may hold already.
    storage.sql.exec("UPDATE envelopes SET body = NULL WHERE hash IN (SELECT json_extract(body, '$.target') FROM envelopes WHERE kind = 'retract' AND body IS NOT NULL)");
  });
}
