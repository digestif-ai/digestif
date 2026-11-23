// POST /v0/envelopes, spec/digestif-relay.json and docs/protocol.md. The checks run in the fake
// relay's order (conformance/src/fake-relay.ts, append and check): size (its Content-Length before
// the body is read), shape, the request, the envelope's own signature and body hash, the signer, an
// unsigned append's author known to the circle, the duplicate, the chain, the daily cap, and last
// the admission fold. The fold's output lands in D1 in one batch with the envelope.
//
// Concurrency: the request is authenticated once (its nonce is spent by then), and the storage
// step, check(), is what a lost race re-runs. check() reads the relay_id it will take and
// everything else it checks in one batch, a transaction that sees one log, so the UNIQUE on
// relay_id is the optimistic token for the whole check: a commit by another append between that
// read and the write batch takes that id, the write fails, and the loser re-reads the duplicate,
// the fold and the chain from the longer log, a few times with jitter (RETRIES). appendSigned() is that path from the envelope checks on, shared with
// the decision a confirmed answer link appends (src/links.ts), which comes in with no request
// signer as a bootstrap append does: the envelope's own signature is the proof.
//
// A join is the one envelope a request signer other than its author may append: an admitted,
// unrevoked member's device pushing a join another relay accepted. The fold judges that join's
// invite expiry by its created_at, and the row records that clock as judged_at so a refold
// reaches the same state; a join the guest sends unsigned is judged at the relay's clock.
import { isoTime, type Json } from "../../conformance/src/encoding.ts";
import {
  bodyMatches,
  ENVELOPE_VERSION,
  envelopeHash,
  isCircleState,
  isKind,
  verifyEnvelope,
  type Envelope,
  type SignedEnvelope,
} from "../../conformance/src/envelope.ts";
import { authenticate, type Authenticated } from "./auth.ts";
import { indexInvites, recordStats, unindexInvite } from "./circles.ts";
import { changedKeys, checkedRoot, CIRCLE_STATE_IDS_SQL, foldLog, keepFold, loadKey, RETRACT_TARGET_SQL, snapshotKeys, type EnvelopeRow, type FoldedIdRow } from "./db.ts";
import type { Relay } from "./env.ts";
import { isMovingAbort, json, moving, Refusal } from "./errors.ts";

export async function append(relay: Relay, request: Request, url: URL): Promise<Response> {
  return appendRaw(relay, request, url, await readBody(relay, request));
}

/** The append's body as text, refused as too_large without buffering past the limit. */
export async function readBody(relay: Pick<Relay, "limits">, request: Request): Promise<string> {
  return new TextDecoder().decode(await readCapped(relay, request));
}

/** The append of a body already read: the founding of a circle reads it first, to see the root. */
export async function appendRaw(relay: Relay, request: Request, url: URL, raw: string): Promise<Response> {
  const signed = parseSigned(raw);
  const { envelope } = signed;
  const bootstrap = envelope.kind === "circle" || envelope.kind === "dinner" || envelope.kind === "join" || isSelfAuthoredDevice(signed);
  const auth = await authenticate(relay, request, url, raw, { allowUnsigned: bootstrap });
  const receipt = await appendSigned(relay, auth, signed);
  await indexAppend(relay, envelope, signed.body ?? null, receipt);
  return json(receipt.status === "duplicate" ? 200 : 201, receipt);
}

/**
 * Keeps the relay's invite index (src/circles.ts) in step with an append: a dinner's or root's
 * invites are indexed, on a duplicate too, so an append retried after a failed index write indexes
 * them; a join's invite, spent, leaves the index.
 */
async function indexAppend(relay: Relay, envelope: Envelope, body: Json, receipt: Receipt): Promise<void> {
  if (envelope.kind === "dinner" || envelope.kind === "circle") {
    await indexInvites(relay.registry, relay.root, guestsOf(body).map((g) => g.invite_key));
  } else if (envelope.kind === "join" && receipt.status === "accepted") {
    await unindexInvite(relay.registry, envelope.author);
  }
}

export function checkSize(relay: Pick<Relay, "limits">, bytes: number): void {
  if (bytes > relay.limits.max_envelope_bytes) {
    throw new Refusal(422, "too_large", `the append is ${bytes} bytes, over ${relay.limits.max_envelope_bytes}`);
  }
}

/**
 * The per-address ceiling on POST /v0/envelopes (wrangler.jsonc, APPEND_LIMITER), checked before
 * the database is touched, so a flood from one address spends no D1 read or write. A deployment
 * without the binding (the tests, wrangler dev) has no ceiling. A node treats the 429 as retry
 * later, never as a refusal of the envelope (docs/protocol.md). DIG-228
 */
export async function throttle(limiter: RateLimit | undefined, request: Request): Promise<void> {
  if (limiter === undefined) return;
  const address = request.headers.get("cf-connecting-ip") ?? "unknown";
  const { success } = await limiter.limit({ key: address });
  if (!success) throw new Refusal(429, "rate_limited", "too many appends from this address; retry in a minute");
}

/**
 * The request body, refused as too_large without buffering it: on its Content-Length before a byte
 * is read, and, for a body that declares none or understates it, as soon as the bytes read pass the
 * limit. DIG-228
 */
export async function readCapped(relay: Pick<Relay, "limits">, request: Request): Promise<Uint8Array> {
  const max = relay.limits.max_envelope_bytes;
  const declared = request.headers.get("content-length");
  if (declared !== null && /^\d+$/.test(declared.trim())) checkSize(relay, Number(declared.trim()));
  if (request.body === null) return new Uint8Array(0);
  const reader = (request.body as ReadableStream<Uint8Array>).getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > max) {
      await reader.cancel();
      throw new Refusal(422, "too_large", `the append is over ${max} bytes`);
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let at = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, at);
    at += chunk.byteLength;
  }
  return bytes;
}

export interface Receipt {
  status: "accepted" | "duplicate";
  relay_id: number;
  hash: string;
}

/**
 * Statements a caller commits in the same batch as the envelope, so they land with it or not at
 * all: a statement that fails rolls the append back (src/links.ts marks the item's links used).
 */
export type AlongWith = (db: D1Database) => D1PreparedStatement[];

/**
 * The append from the envelope checks on, after the request is authenticated: the signature and
 * body hash, the signer against the author, then the storage step with its lost-race re-run.
 * `along` runs only when the envelope is accepted, not on a duplicate.
 */
export async function appendSigned(relay: Relay, auth: Authenticated, signed: SignedEnvelope, along?: AlongWith): Promise<Receipt> {
  const { envelope } = signed;
  if (!verifyEnvelope(envelope)) throw new Refusal(422, "bad_signature", "the envelope signature does not verify");
  if (signed.body !== undefined && !bodyMatches(signed)) throw new Refusal(422, "bad_signature", "body_hash does not match the body");
  if (signed.body === undefined) throw new Refusal(422, "malformed", "an append carries its body");
  if (auth.key !== undefined && auth.key !== envelope.author && !isPushedJoin(auth, envelope)) {
    throw new Refusal(401, "not_admitted", "the request signer is not the envelope author");
  }
  const hash = envelopeHash(envelope);
  if (auth.key === undefined) await checkBootstrapAuthor(relay, signed, hash);
  const judgedAt = clockFor(relay, auth, envelope);
  for (let attempt = 0; ; attempt++) {
    try {
      return await check(relay, envelope, signed.body, hash, judgedAt, along);
    } catch (error) {
      if (!isLostRace(error) || attempt >= RETRIES) throw error;
    }
    await backoff(attempt);
  }
}

/**
 * An append no request signer vouches for (a dinner, a join, a self-authored device message, or the
 * decision an answer link confirms) is refused before the fold unless the circle already knows the
 * key it rests on: the join's invite key in invites, the self-authored device's identity in
 * admitted_keys, any other envelope's author as a device or mail key there, revoked or not, since
 * the fold reads a revoked key inside its cutoff. One indexed read, so a self-generated key costs
 * the relay no fold. The circle root is the one envelope that rests on nothing. Each refusal is the
 * one the fold would give, 422 not_admitted. DIG-228
 */
async function checkBootstrapAuthor(relay: Relay, signed: SignedEnvelope, hash: string): Promise<void> {
  if (hash === relay.root) return;
  const { envelope } = signed;
  let known: boolean;
  if (envelope.kind === "join") {
    known = (await relay.db.prepare("SELECT 1 AS found FROM invites WHERE key = ?").bind(envelope.author).first()) !== null;
  } else if (isSelfAuthoredDevice(signed)) {
    const identity = isObject(signed.body) ? signed.body["identity_key"] : undefined;
    if (typeof identity !== "string") return; // the fold refuses the shape as malformed
    known = (await loadKey(relay.db, identity))?.role === "identity";
  } else {
    const state = await loadKey(relay.db, envelope.author);
    known = state !== undefined && state.role !== "identity";
  }
  if (!known) throw new Refusal(422, "not_admitted", `the circle does not know the key this ${envelope.kind} rests on`);
}

/**
 * A join an admitted member's device pushes with a signed request: authenticate() has already
 * refused a signer that is not an admitted, unrevoked device or mail key, so a signed join is one
 * a member replicates from another relay (docs/protocol.md, The admission fold).
 */
function isPushedJoin(auth: Authenticated, envelope: Envelope): boolean {
  return envelope.kind === "join" && auth.key !== undefined;
}

/**
 * The clock the fold judges this append at. A join a member pushes is judged by its created_at,
 * as every node judges it; everything else, the join the guest sends unsigned included, at the
 * relay's own clock, since nothing checks an unsigned join's created_at.
 */
function clockFor(relay: Relay, auth: Authenticated, envelope: Envelope): Date {
  if (!isPushedJoin(auth, envelope)) return relay.now;
  const created = new Date(envelope.created_at);
  if (Number.isNaN(created.getTime())) throw new Refusal(422, "malformed", "the join's created_at is not a time");
  return created;
}

/**
 * How many times a lost race (another append committed first) is re-run before it is a 500. Each
 * re-run waits a random moment first, longer each time, so appends that lost together do not
 * collide again in step. DIG-234
 */
const RETRIES = 5;
const RETRY_BASE_MS = 10;

function backoff(attempt: number): Promise<void> {
  const ms = Math.random() * RETRY_BASE_MS * 2 ** attempt;
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** D1 reports two appends taking one relay_id, or one hash, as the envelopes table's UNIQUE failing. */
function isLostRace(error: unknown): boolean {
  return error instanceof Error && /UNIQUE constraint failed: envelopes\./.test(error.message);
}

/** What the check reads of the log, all in one batch: one transaction, so every read sees the same log. */
interface LogReads {
  position: number;
  held: number | undefined;
  root: string | undefined;
  cutover: number;
  ids: FoldedIdRow[];
  atSeq: string | undefined;
  last: number;
  daily: number;
  retractKind: string | undefined;
  retractAuthor: string | undefined;
  /** The bytes the circle's store holds, as the batch's first read reports them. */
  size: number;
}

/**
 * The check's reads in one round trip. The batch is a transaction, so every read sees exactly the
 * log below the position it reads first, and none needs the position as a bound. DIG-234
 */
async function readLog(relay: Relay, envelope: Envelope, hash: string, day: string, retractTarget: string | undefined): Promise<LogReads> {
  const db = relay.db;
  const results = await db.batch<Record<string, unknown>>([
    db.prepare("SELECT COALESCE(MAX(relay_id), 0) + 1 AS next FROM envelopes"),
    db.prepare("SELECT relay_id FROM envelopes WHERE hash = ?").bind(hash),
    db.prepare("SELECT root, admission_cutover FROM circle WHERE id = 1"),
    db.prepare(CIRCLE_STATE_IDS_SQL).bind(Number.MAX_SAFE_INTEGER),
    db.prepare("SELECT hash FROM envelopes WHERE author = ? AND seq = ?").bind(envelope.author, envelope.seq),
    db.prepare("SELECT MAX(seq) AS last FROM envelopes WHERE author = ?").bind(envelope.author),
    db.prepare("SELECT count FROM daily_appends WHERE author = ? AND day = ?").bind(envelope.author, day),
    db.prepare(RETRACT_TARGET_SQL).bind(retractTarget ?? ""),
  ]);
  const first = (i: number): Record<string, unknown> | undefined => results[i]?.results[0];
  const circle = first(2) as { root: string; admission_cutover: number } | undefined;
  const target = retractTarget === undefined ? undefined : (first(7) as { kind: string; author: string } | undefined);
  return {
    position: (first(0)?.["next"] as number | undefined) ?? 1,
    held: first(1)?.["relay_id"] as number | undefined,
    root: circle?.root,
    cutover: circle?.admission_cutover ?? 0,
    ids: (results[3]?.results ?? []) as unknown as FoldedIdRow[],
    atSeq: first(4)?.["hash"] as string | undefined,
    last: (first(5)?.["last"] as number | null | undefined) ?? 0,
    daily: (first(6)?.["count"] as number | undefined) ?? 0,
    retractKind: target?.kind,
    retractAuthor: target?.author,
    size: results[0]?.meta.size_after ?? 0,
  };
}

/**
 * The storage step, re-run on a lost race. The position, the duplicate, the chain, the cap, the
 * retract target and the fold's inputs are read in one batch, so they describe the log this append
 * extends, and nothing another append commits after that batch can pass unseen: it takes this
 * relay_id and the write batch fails.
 */
async function check(relay: Relay, envelope: Envelope, body: Json, hash: string, judgedAt: Date, along?: AlongWith): Promise<Receipt> {
  const day = isoTime(relay.now).slice(0, 10);
  const retractTarget = envelope.kind === "retract" ? targetOf(body) : undefined;
  const log = await readLog(relay, envelope, hash, day, retractTarget);
  checkedRoot(relay.db, relay.root, log.root);
  const { position } = log;
  if (log.held !== undefined) return { status: "duplicate", relay_id: log.held, hash };
  if (log.size >= relay.hosting.circle_storage) {
    throw new Refusal(507, "circle_full", `this circle holds ${log.size} bytes on this relay, its whole share of ${relay.hosting.circle_storage}`);
  }
  const fold = await foldLog(relay.db, relay.root, {
    before: position,
    signers: relay.releaseSigners,
    read: { cutover: log.cutover, ids: log.ids },
  });
  // The kept fold holds the circle-state envelopes; a retract's target is any envelope below the
  // position, whose author the retract rule reads off the row rather than a replay of the log.
  if (retractTarget !== undefined && log.retractAuthor !== undefined) fold.recordAuthor(retractTarget, log.retractAuthor);
  const author = fold.activeAuthor(envelope.author);
  if (envelope.kind !== "join") checkChain(envelope, hash, author?.role === "mail", log);
  if (log.daily >= relay.limits.max_appends_per_device_per_day) {
    throw new Refusal(429, "rate_limited", `this key has made ${relay.limits.max_appends_per_device_per_day} appends today`);
  }
  if (log.retractKind !== undefined && isCircleState(log.retractKind)) {
    throw new Refusal(422, "malformed", `a retract cannot drop a ${log.retractKind}, which the fold reads`);
  }
  const before = snapshotKeys(fold);
  const epochBefore = fold.epoch;
  const error = fold.apply({ hash, envelope, body, position, now: judgedAt });
  if (error !== null) throw new Refusal(422, error, `the fold refused this ${envelope.kind}`);

  const db = relay.db;
  const row: EnvelopeRow = {
    relay_id: position,
    hash,
    author: envelope.author,
    seq: envelope.seq,
    kind: envelope.kind,
    epoch: envelope.epoch,
    created_at: envelope.created_at,
    received_at: isoTime(relay.now),
    judged_at: judgedAt === relay.now ? null : isoTime(judgedAt),
    envelope: JSON.stringify(envelope),
    body: JSON.stringify(body),
  };
  const statements: D1PreparedStatement[] = [
    db
      .prepare(
        "INSERT INTO envelopes (relay_id, hash, author, seq, kind, epoch, created_at, received_at, judged_at, envelope, body) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      )
      .bind(row.relay_id, row.hash, row.author, row.seq, row.kind, row.epoch, row.created_at, row.received_at, row.judged_at, row.envelope, row.body),
    db
      .prepare("INSERT INTO daily_appends (author, day, count) VALUES (?, ?, 1) ON CONFLICT (author, day) DO UPDATE SET count = count + 1")
      .bind(envelope.author, day),
  ];
  for (const state of changedKeys(before, fold)) {
    statements.push(
      db
        .prepare(
          "INSERT OR REPLACE INTO admitted_keys (key, role, identity, admitted_at, join_epoch, revoked_at, after_seq, mail_read) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(
          state.key,
          state.role,
          state.identity,
          state.admitted_at,
          state.join_epoch,
          state.revoked_at ?? null,
          state.after_seq ?? null,
          state.mail_read === undefined ? null : JSON.stringify([...state.mail_read].sort()),
        ),
    );
  }
  if (fold.epoch !== epochBefore) statements.push(db.prepare("UPDATE circle SET epoch = ? WHERE id = 1").bind(fold.epoch));
  if (envelope.kind === "dinner" || envelope.kind === "circle") {
    // The fold recorded these guests (recordGuests): the first circle or dinner listing an invite key wins.
    for (const guest of guestsOf(body)) {
      statements.push(db.prepare("INSERT OR IGNORE INTO invites (key, dinner, expires_at, spent) VALUES (?, ?, ?, 0)").bind(guest.invite_key, hash, guest.expires_at));
    }
  }
  if (envelope.kind === "join") statements.push(db.prepare("UPDATE invites SET spent = 1 WHERE key = ?").bind(envelope.author));
  if (retractTarget !== undefined) statements.push(db.prepare("UPDATE envelopes SET body = NULL WHERE hash = ?").bind(retractTarget));
  if (along !== undefined) statements.push(...along(db));
  try {
    await db.batch(statements);
  } catch (error) {
    if (isMovingAbort(error)) throw moving();
    throw error;
  }
  keepFold(fold, row);
  await recordStats(relay.registry, relay.root, log.size, relay.now);
  return { status: "accepted", relay_id: position, hash };
}

/**
 * The sequence and fork rules, over the log the check read. A join is its invite key's only
 * envelope, so the spent rule covers it. A retract naming a circle-state envelope is refused in
 * check(): the fold is replayed from those bodies, so dropping one would leave the log unfoldable.
 */
function checkChain(envelope: Envelope, hash: string, mail: boolean, log: LogReads): void {
  if (log.atSeq !== undefined && log.atSeq !== hash) {
    throw new Refusal(422, "fork", `a different envelope from this author at seq ${envelope.seq} is already held`);
  }
  if (!mail && envelope.seq <= log.last) {
    throw new Refusal(422, "sequence_regression", `seq ${envelope.seq} is not greater than ${log.last}, the last held`);
  }
}

/** A device message authored by the key it admits: the lost-laptop bootstrap, proved by the identity signature inside it. */
function isSelfAuthoredDevice(signed: SignedEnvelope): boolean {
  const body = signed.body;
  return signed.envelope.kind === "device" && isObject(body) && body["key"] === signed.envelope.author;
}

function isObject(value: Json | undefined): value is { [key: string]: Json } {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function targetOf(body: Json): string | undefined {
  return isObject(body) && typeof body["target"] === "string" ? body["target"] : undefined;
}

/** The guests of a dinner the fold accepted, so each has an invite_key and an expires_at. */
function guestsOf(body: Json): Array<{ invite_key: string; expires_at: string }> {
  if (!isObject(body) || !Array.isArray(body["guests"])) return [];
  const guests: Array<{ invite_key: string; expires_at: string }> = [];
  for (const guest of body["guests"]) {
    if (isObject(guest) && typeof guest["invite_key"] === "string" && typeof guest["expires_at"] === "string") {
      guests.push({ invite_key: guest["invite_key"], expires_at: guest["expires_at"] });
    }
  }
  return guests;
}

/** A signed_envelope from its JSON text, or `422 malformed`. */
export function parseSigned(raw: string): SignedEnvelope {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new Refusal(422, "malformed", "the body is not JSON");
  }
  const signed = value as SignedEnvelope | null;
  const e = isObject(signed as Json) ? (signed as SignedEnvelope).envelope : undefined;
  const wellFormed =
    e !== undefined &&
    e !== null &&
    typeof e === "object" &&
    e.version === ENVELOPE_VERSION &&
    typeof e.author === "string" &&
    Number.isInteger(e.seq) &&
    e.seq >= 1 &&
    (e.prev === undefined || typeof e.prev === "string") &&
    typeof e.created_at === "string" &&
    Number.isInteger(e.epoch) &&
    e.epoch >= 0 &&
    isKind(e.kind) &&
    typeof e.body_hash === "string" &&
    typeof e.signature === "string";
  if (!wellFormed) throw new Refusal(422, "malformed", "the envelope does not parse");
  return signed as SignedEnvelope;
}
