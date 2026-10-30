// The reads: GET /v0/envelopes, GET /v0/circle and the bootstrap read GET /v0/invites/:invite_key.
import { CIRCLE_STATE_KINDS } from "../../conformance/src/envelope.ts";
import { HEADER_KEY } from "../../conformance/src/request.ts";
import { authenticate } from "./auth.ts";
import { circleEpoch, ENVELOPE_COLUMNS, keyJson, loadEnvelope, loadKey, loadKeys, storedOf, type EnvelopeRow } from "./db.ts";
import type { Relay } from "./env.ts";
import { empty, json, Refusal } from "./errors.ts";

/** The reader's join epoch: the floor for the content they may fetch. */
async function readerEpoch(relay: Relay, request: Request, url: URL): Promise<number> {
  const auth = await authenticate(relay, request, url, "");
  if (auth.key === undefined) return 0;
  return (await loadKey(relay.db, auth.key))?.join_epoch ?? 0;
}

function integer(value: string | null, fallback: number): number {
  if (value === null || value === "") return fallback;
  const n = Number(value);
  return Number.isInteger(n) ? n : fallback;
}

/** Everything after a cursor in relay_id order: circle state in full, content from the reader's join epoch on. */
export async function page(relay: Relay, request: Request, url: URL): Promise<Response> {
  const floor = await readerEpoch(relay, request, url);
  const after = Math.max(0, integer(url.searchParams.get("after"), 0));
  const limit = Math.max(1, Math.min(integer(url.searchParams.get("limit"), relay.limits.max_page_size), relay.limits.max_page_size));
  const kinds = CIRCLE_STATE_KINDS.map((k) => `'${k}'`).join(", ");
  const { results } = await relay.db
    .prepare(`SELECT ${ENVELOPE_COLUMNS} FROM envelopes WHERE relay_id > ? AND (kind IN (${kinds}) OR epoch >= ?) ORDER BY relay_id LIMIT ?`)
    .bind(after, floor, limit + 1)
    .all<EnvelopeRow>();
  const rows = results.slice(0, limit);
  const last = rows[rows.length - 1];
  const more = results.length > limit && last !== undefined;
  return json(200, { envelopes: rows.map(storedOf), ...(more ? { next: last.relay_id } : {}) });
}

/** The root, the epoch, the admitted keys and the limits, to an admitted reader. */
export async function circle(relay: Relay, request: Request, url: URL): Promise<Response> {
  await readerEpoch(relay, request, url);
  const keys = (await loadKeys(relay.db)).map((state) => {
    const { mail_read: _mailRead, ...reported } = keyJson(state) as { [key: string]: unknown };
    return reported;
  });
  return json(200, { root: relay.root, epoch: await circleEpoch(relay.db), keys, limits: relay.limits });
}

/**
 * The bootstrap read: the dinner listing an open invite, to the invite key alone. An unknown, spent
 * or expired invite is 404 with no body, one answer for all three; another signer is 401.
 */
export async function invite(relay: Relay, request: Request, url: URL, inviteKey: string): Promise<Response> {
  if (request.headers.get(HEADER_KEY) !== inviteKey) throw new Refusal(401, "not_admitted", "the bootstrap read is signed by the invite key it names");
  await authenticate(relay, request, url, "", { admitted: false });
  const row = await relay.db.prepare("SELECT dinner, expires_at, spent FROM invites WHERE key = ?").bind(inviteKey).first<{ dinner: string; expires_at: string; spent: number }>();
  if (row === null || row.spent !== 0 || Date.parse(row.expires_at) <= relay.now.getTime()) return empty(404);
  const dinner = await loadEnvelope(relay.db, row.dinner);
  if (dinner === undefined) return empty(404);
  return json(200, storedOf(dinner));
}
