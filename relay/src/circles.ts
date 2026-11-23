// The circles a relay hosts (docs/protocol.md, Hosted circles): the registry in the relay's D1
// (migrations/0006_hosted_circles.sql), each circle's address, which store answers for it, and the
// founding of a new one, which a voucher from a member of a circle the relay already hosts opens.
//
// A circle's address is `<base>/c/<root hex>`, and every circle route answers only there: an
// unprefixed one answers 410 circle_moved naming the home circle's (HOME_ROOT, else CIRCLE_ROOT).
// The home circle's state stays in the relay's D1 until its log has moved into its own store (src/move.ts); every
// other circle's state lives in its store from the moment it opens.
import { isoTime } from "../../conformance/src/encoding.ts";
import { HEADER_VOUCHER, readVoucher, VOUCHER_TTL_MS } from "../../conformance/src/voucher.ts";
import { loadKey } from "./db.ts";
import type { HostingLimits } from "./env.ts";
import { moving, Refusal } from "./errors.ts";
import { circleDatabase } from "./store.ts";

export const CIRCLE_PREFIX = "/c/";
const HEX = /^[0-9a-f]{64}$/;

/** One row of hosted_circles. */
export interface HostedRow {
  root: string;
  opened_at: string;
  vouched_by: string | null;
  vouched_identity: string | null;
  state: "open" | "suspended";
  state_changed_at: string;
  store: "d1" | "moving" | "draining" | "object";
  size: number;
  last_append_at: string | null;
}

const HOSTED_COLUMNS = "root, opened_at, vouched_by, vouched_identity, state, state_changed_at, store, size, last_append_at";

/** The root a path's `/c/<hex>` names, and the rest of the path; undefined for a path outside every circle. */
export function circlePath(path: string): { root: string; rest: string } | undefined {
  if (!path.startsWith(CIRCLE_PREFIX)) return undefined;
  const hex = path.slice(CIRCLE_PREFIX.length, CIRCLE_PREFIX.length + 64);
  const rest = path.slice(CIRCLE_PREFIX.length + 64);
  if (!HEX.test(hex) || (rest !== "" && !rest.startsWith("/"))) throw new Refusal(404, "circle_unknown", `${path} names no circle: a circle's address is /c/<the 64 hex digits of its root>`);
  return { root: `sha256:${hex}`, rest };
}

/** The base url a relay's addresses start from: RELAY_URL when set, else the request's origin. */
export function baseOf(env: Env, url: URL): string {
  const configured = env.RELAY_URL;
  return configured === undefined || configured === "" ? url.origin : configured.replace(/\/+$/, "");
}

/** A circle's address on the relay at [base]. */
export function addressOf(base: string, root: string): string {
  return `${base}${CIRCLE_PREFIX}${root.slice("sha256:".length)}`;
}

export async function hostedRow(registry: D1Database, root: string): Promise<HostedRow | undefined> {
  const row = await registry.prepare(`SELECT ${HOSTED_COLUMNS} FROM hosted_circles WHERE root = ?`).bind(root).first<HostedRow>();
  return row ?? undefined;
}

/**
 * The home circle's row, made on its first request: kept in D1 (store `d1`) when the move is off,
 * else `moving`, and the move started (src/move.ts). A row left at `d1` starts moving once the move
 * is on.
 */
export async function homeRow(env: Env, home: string, hosting: HostingLimits, now: Date): Promise<HostedRow> {
  const registry = env.DB;
  let row = await hostedRow(registry, home);
  if (row === undefined) {
    const at = isoTime(now);
    await registry
      .prepare("INSERT OR IGNORE INTO hosted_circles (root, opened_at, state, state_changed_at, store) VALUES (?, ?, 'open', ?, 'd1')")
      .bind(home, at, at)
      .run();
    row = await hostedRow(registry, home);
    if (row === undefined) throw new Error(`the home circle ${home} has no registry row after its insert`);
  }
  if (hosting.move_rows_per_day > 0 && (row.store === "d1" || row.store === "moving")) await startMove(env, home, hosting.move_rows_per_day);
  return row;
}

/** Roots whose move this isolate has asked its store to drive, so a busy circle asks once. */
const moveAsked = new Set<string>();

/**
 * Marks the home circle moving and asks its store to drive the copy (src/move.ts). The store keeps
 * its own progress and alarm, so asking again is harmless; an isolate asks once.
 */
export async function startMove(env: Env, home: string, rowsPerDay: number, batch?: number): Promise<void> {
  if (moveAsked.has(home)) return;
  await env.DB.prepare("UPDATE hosted_circles SET store = 'moving' WHERE root = ? AND store = 'd1'").bind(home).run();
  await env.CIRCLE_STORE.get(env.CIRCLE_STORE.idFromName(home)).startMove(home, rowsPerDay, batch);
  moveAsked.add(home);
}

/** Forgets which moves this isolate asked for, as a fresh isolate starts: for the tests. */
export function forgetMoves(): void {
  moveAsked.clear();
}

const handles = new Map<string, D1Database>();

/**
 * The database a circle's routes read and write: the relay's D1 for a home circle not yet moved, else
 * the circle's own store, one handle per root per isolate so src/db.ts's per-handle checks hold.
 */
export function databaseFor(env: Env, row: HostedRow): D1Database {
  if (row.store !== "object") return env.DB;
  let db = handles.get(row.root);
  if (db === undefined) {
    db = circleDatabase(env.CIRCLE_STORE, row.root);
    handles.set(row.root, db);
  }
  return db;
}

/** A suspended circle answers 410 at every route; a draining one refuses writes until it has moved. */
export function checkState(row: HostedRow, writing: boolean): void {
  if (row.state === "suspended") throw new Refusal(410, "circle_suspended", `this relay's operator suspended circle ${shortRoot(row.root)}`);
  if (writing && row.store === "draining") throw moving();
}

/** A root's short form on every screen: its first 12 hex digits. */
export function shortRoot(root: string): string {
  return root.slice("sha256:".length, "sha256:".length + 12);
}

const DAY_MS = 24 * 60 * 60 * 1000;
const MEMBER_WINDOW_MS = 30 * DAY_MS;

/** What a founding carries besides the root: the request (its voucher header) and its url (the host it names). */
export interface Founding {
  root: string;
  /** The relay's home circle, whose members vouch like any hosted circle's. */
  home: string | null;
  request: Request;
  url: URL;
  hosting: HostingLimits;
  now: Date;
  skewSeconds: number;
}

/**
 * Opens a circle for its root's bootstrap append (docs/protocol.md, Hosted circles): the relay hosts
 * it when it hosts at all, a member of a circle it already hosts vouched for it, that member has not
 * opened too many circles here lately, and every hosted circle's reserved share still fits. Each
 * refusal has its own code. Answers the new row; the caller appends the root to its store and
 * closes the row again when the store refuses the root.
 */
export async function found(env: Env, founding: Founding): Promise<HostedRow> {
  const { root, hosting, now } = founding;
  if (!hosting.hosting) throw new Refusal(403, "not_hosting", "this relay's operator has stopped it hosting new circles");
  const voucher = await vouched(env, founding);
  const registry = env.DB;
  const since = isoTime(new Date(now.getTime() - MEMBER_WINDOW_MS));
  const recent = await registry
    .prepare("SELECT COUNT(*) AS n, MIN(opened_at) AS first FROM hosted_circles WHERE vouched_by = ? AND vouched_identity = ? AND opened_at > ?")
    .bind(voucher.circle, voucher.identity, since)
    .first<{ n: number; first: string | null }>();
  if (recent !== null && recent.n >= hosting.circles_per_member) {
    const next = recent.first === null ? now : new Date(Date.parse(recent.first) + MEMBER_WINDOW_MS);
    throw new Refusal(429, "too_many_circles", `this member has opened ${recent.n} circles on this relay in 30 days; the next opens on ${isoTime(next).slice(0, 10)}`);
  }
  const at = isoTime(now);
  // The share check and the insert are one statement, so two foundings at once cannot both take the last share.
  const opened = await registry
    .prepare(
      "INSERT INTO hosted_circles (root, opened_at, vouched_by, vouched_identity, state, state_changed_at, store) " +
        "SELECT ?1, ?2, ?3, ?4, 'open', ?2, 'object' WHERE ((SELECT COUNT(*) FROM hosted_circles) + 1) * ?5 <= ?6 " +
        "ON CONFLICT (root) DO NOTHING",
    )
    .bind(root, at, voucher.circle, voucher.identity, hosting.circle_storage, hosting.relay_storage)
    .run();
  const row = await hostedRow(registry, root);
  if (row !== undefined) return row;
  if (opened.meta.changes === 0) {
    throw new Refusal(507, "relay_full", `this relay's circles hold their whole share of its storage; another ${hosting.circle_storage} bytes would pass ${hosting.relay_storage}`);
  }
  throw new Error(`circle ${root} has no registry row after it opened`);
}

/** Closes a circle whose store refused its root, so a founding that failed leaves nothing hosted. */
export async function unfound(env: Env, root: string): Promise<void> {
  await env.DB.prepare("DELETE FROM hosted_circles WHERE root = ? AND vouched_by IS NOT NULL").bind(root).run();
}

/**
 * The voucher on a founding append, checked: well formed and signed, for this root and this relay,
 * unexpired and not dated further out than ten minutes, by an admitted, unrevoked device key of an
 * open circle this relay hosts. Answers the vouching circle and the member's identity there.
 */
async function vouched(env: Env, founding: Founding): Promise<{ circle: string; identity: string }> {
  const header = founding.request.headers.get(HEADER_VOUCHER);
  if (header === null) throw new Refusal(403, "not_vouched", "a new circle is hosted only for a member of a circle this relay hosts: the founding append carries their Digestif-Voucher");
  const voucher = readVoucher(header);
  if (typeof voucher === "string") throw new Refusal(403, "not_vouched", voucher);
  if (voucher.root !== founding.root) throw new Refusal(403, "not_vouched", "the voucher names another root");
  const hosts = new Set([founding.url.host, new URL(baseOf(env, founding.url)).host]);
  if (!hosts.has(voucher.relay)) throw new Refusal(403, "not_vouched", `the voucher names relay ${voucher.relay}, not ${[...hosts].join(" or ")}`);
  const expires = Date.parse(voucher.expires_at);
  const now = founding.now.getTime();
  if (Number.isNaN(expires) || expires <= now) throw new Refusal(403, "not_vouched", "the voucher has expired");
  if (expires > now + VOUCHER_TTL_MS + founding.skewSeconds * 1000) throw new Refusal(403, "not_vouched", "the voucher is good for longer than ten minutes");
  const circle =
    voucher.circle === founding.root
      ? undefined
      : voucher.circle === founding.home
        ? await homeRow(env, voucher.circle, founding.hosting, founding.now)
        : await hostedRow(env.DB, voucher.circle);
  if (circle === undefined || circle.state !== "open") throw new Refusal(403, "not_vouched", "the voucher names no open circle this relay hosts");
  const key = await loadKey(databaseFor(env, circle), voucher.key);
  if (key === undefined || key.role !== "device" || key.revoked_at !== undefined) throw new Refusal(403, "not_vouched", "the voucher's key is not an admitted device of the circle it names");
  return { circle: voucher.circle, identity: key.identity };
}

/** The writes of the stats an operator's list reads, at most one per circle an hour per isolate unless the size moved a MiB. */
const statsWritten = new Map<string, { at: number; size: number }>();
const STATS_EVERY_MS = 60 * 60 * 1000;
const STATS_SIZE_STEP = 1024 * 1024;

/**
 * Records a circle's size and last append in its registry row, sparingly. The append it follows has
 * committed, so a failed write is logged, never the append's answer.
 */
export async function recordStats(registry: D1Database, root: string, size: number, now: Date): Promise<void> {
  const last = statsWritten.get(root);
  if (last !== undefined && now.getTime() - last.at < STATS_EVERY_MS && Math.abs(size - last.size) < STATS_SIZE_STEP) return;
  statsWritten.set(root, { at: now.getTime(), size });
  try {
    await registry.prepare("UPDATE hosted_circles SET size = ?, last_append_at = ? WHERE root = ?").bind(size, isoTime(now), root).run();
  } catch (error) {
    statsWritten.delete(root);
    console.error(`hosted circle ${root}: the size and last append were not recorded`, error);
  }
}

/** Indexes the open invites a dinner or root lists, for the relay's own bootstrap read. */
export async function indexInvites(registry: D1Database, root: string, keys: string[]): Promise<void> {
  if (keys.length === 0) return;
  await registry.batch(keys.map((key) => registry.prepare("INSERT OR IGNORE INTO invite_index (key, root) VALUES (?, ?)").bind(key, root)));
}

/** Drops a spent invite from the index. */
export async function unindexInvite(registry: D1Database, key: string): Promise<void> {
  await registry.prepare("DELETE FROM invite_index WHERE key = ?").bind(key).run();
}

/** The circle an open invite key belongs to, by the index. */
export async function inviteCircle(registry: D1Database, key: string): Promise<string | undefined> {
  const row = await registry.prepare("SELECT root FROM invite_index WHERE key = ?").bind(key).first<{ root: string }>();
  return row?.root;
}

/** The isolate's last write of the unprefixed-request time, so a busy relay writes it rarely. */
let unprefixedWritten = 0;
const UNPREFIXED_EVERY_MS = 10 * 60 * 1000;

/**
 * Records that something still reached a circle route unprefixed, at most every ten minutes per
 * isolate: GET /v0/relay reports the time, so an operator sees a node that never moved to its
 * circle's address (docs/protocol.md, Hosted circles).
 */
export async function recordUnprefixed(registry: D1Database, now: Date): Promise<void> {
  if (now.getTime() - unprefixedWritten < UNPREFIXED_EVERY_MS) return;
  unprefixedWritten = now.getTime();
  await registry
    .prepare("INSERT INTO relay_state (id, last_unprefixed_at) VALUES (1, ?1) ON CONFLICT (id) DO UPDATE SET last_unprefixed_at = ?1")
    .bind(isoTime(now))
    .run();
}

/** Forgets the isolate's write memos, as a fresh isolate starts: for the tests. */
export function forgetMemos(): void {
  unprefixedWritten = 0;
  statsWritten.clear();
  handles.clear();
  moveAsked.clear();
}
