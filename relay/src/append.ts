// POST /v0/envelopes, spec/digestif-relay.json and docs/protocol.md. The checks run in the fake
// relay's order (conformance/src/fake-relay.ts, append and check): size, shape, the request, the
// envelope's own signature and body hash, the duplicate, the signer, the chain, the daily cap, and
// last the admission fold. The fold's output lands in D1 in one batch with the envelope.
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
import { changedKeys, foldLog, snapshotKeys, type EnvelopeRow } from "./db.ts";
import type { Relay } from "./env.ts";
import { json, Refusal } from "./errors.ts";

export async function append(relay: Relay, request: Request, url: URL): Promise<Response> {
  const bytes = await request.arrayBuffer();
  if (bytes.byteLength > relay.limits.max_envelope_bytes) {
    throw new Refusal(422, "too_large", `the append is ${bytes.byteLength} bytes, over ${relay.limits.max_envelope_bytes}`);
  }
  const raw = new TextDecoder().decode(bytes);
  const signed = parseSigned(raw);
  const { envelope } = signed;
  const bootstrap = envelope.kind === "dinner" || envelope.kind === "join" || isSelfAuthoredDevice(signed);
  const auth = await authenticate(relay, request, url, raw, { allowUnsigned: bootstrap });
  if (!verifyEnvelope(envelope)) throw new Refusal(422, "bad_signature", "the envelope signature does not verify");
  if (signed.body !== undefined && !bodyMatches(signed)) throw new Refusal(422, "bad_signature", "body_hash does not match the body");
  if (signed.body === undefined) throw new Refusal(422, "malformed", "an append carries its body");
  const hash = envelopeHash(envelope);
  const held = await relay.db.prepare("SELECT relay_id FROM envelopes WHERE hash = ?").bind(hash).first<{ relay_id: number }>();
  if (held !== null) return json(200, { status: "duplicate", relay_id: held.relay_id, hash });
  return json(201, await check(relay, auth, envelope, signed.body, hash));
}

async function check(relay: Relay, auth: Authenticated, envelope: Envelope, body: Json, hash: string): Promise<Json> {
  if (auth.key !== undefined && auth.key !== envelope.author) {
    throw new Refusal(401, "not_admitted", "the request signer is not the envelope author");
  }
  const retractTarget = envelope.kind === "retract" ? targetOf(body) : undefined;
  const fold = await foldLog(relay.db, relay.root, { include: retractTarget });
  const author = fold.activeAuthor(envelope.author);
  if (envelope.kind !== "join") await checkChain(relay, envelope, hash, author?.role === "mail");
  const day = isoTime(relay.now).slice(0, 10);
  const daily = await relay.db.prepare("SELECT count FROM daily_appends WHERE author = ? AND day = ?").bind(envelope.author, day).first<{ count: number }>();
  if ((daily?.count ?? 0) >= relay.limits.max_appends_per_device_per_day) {
    throw new Refusal(429, "rate_limited", `this key has made ${relay.limits.max_appends_per_device_per_day} appends today`);
  }
  if (retractTarget !== undefined) await checkRetractTarget(relay, retractTarget);
  const next = await relay.db.prepare("SELECT COALESCE(MAX(relay_id), 0) + 1 AS next FROM envelopes").first<{ next: number }>();
  const position = next?.next ?? 1;
  const before = snapshotKeys(fold);
  const epochBefore = fold.epoch;
  const error = fold.apply({ hash, envelope, body, position, now: relay.now });
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
    envelope: JSON.stringify(envelope),
    body: JSON.stringify(body),
  };
  const statements: D1PreparedStatement[] = [
    db
      .prepare(
        "INSERT INTO envelopes (relay_id, hash, author, seq, kind, epoch, created_at, received_at, envelope, body) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      )
      .bind(row.relay_id, row.hash, row.author, row.seq, row.kind, row.epoch, row.created_at, row.received_at, row.envelope, row.body),
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
  if (envelope.kind === "dinner") {
    // The fold recorded these guests (recordGuests): the first dinner listing an invite key wins.
    for (const guest of guestsOf(body)) {
      statements.push(db.prepare("INSERT OR IGNORE INTO invites (key, dinner, expires_at, spent) VALUES (?, ?, ?, 0)").bind(guest.invite_key, hash, guest.expires_at));
    }
  }
  if (envelope.kind === "join") statements.push(db.prepare("UPDATE invites SET spent = 1 WHERE key = ?").bind(envelope.author));
  if (retractTarget !== undefined) statements.push(db.prepare("UPDATE envelopes SET body = NULL WHERE hash = ?").bind(retractTarget));
  await db.batch(statements);
  return { status: "accepted", relay_id: position, hash };
}

/** The sequence and fork rules. A join is its invite key's only envelope, so the spent rule covers it. */
async function checkChain(relay: Relay, envelope: Envelope, hash: string, mail: boolean): Promise<void> {
  const [atSeq, chain] = await relay.db.batch<{ hash: string } | { last: number | null }>([
    relay.db.prepare("SELECT hash FROM envelopes WHERE author = ? AND seq = ?").bind(envelope.author, envelope.seq),
    relay.db.prepare("SELECT MAX(seq) AS last FROM envelopes WHERE author = ?").bind(envelope.author),
  ]);
  const held = atSeq?.results[0] as { hash: string } | undefined;
  if (held !== undefined && held.hash !== hash) {
    throw new Refusal(422, "fork", `a different envelope from this author at seq ${envelope.seq} is already held`);
  }
  const last = (chain?.results[0] as { last: number | null } | undefined)?.last ?? 0;
  if (!mail && envelope.seq <= last) {
    throw new Refusal(422, "sequence_regression", `seq ${envelope.seq} is not greater than ${last}, the last held`);
  }
}

/**
 * A retract drops its target's body, and the fold is replayed from the circle-state envelopes'
 * bodies, so a retract naming one of those would leave the log unfoldable: it is refused. The
 * protocol fixes retracts for content; this is the relay's reading of what a retract of a dinner,
 * join, device or revoke would mean.
 */
async function checkRetractTarget(relay: Relay, target: string): Promise<void> {
  const row = await relay.db.prepare("SELECT kind FROM envelopes WHERE hash = ?").bind(target).first<{ kind: string }>();
  if (row !== null && isCircleState(row.kind)) throw new Refusal(422, "malformed", `a retract cannot drop a ${row.kind}, which the fold reads`);
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

function parseSigned(raw: string): SignedEnvelope {
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
