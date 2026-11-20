// The reads: GET /v0/envelopes, GET /v0/circle and the bootstrap read GET /v0/invites/:invite_key.
import { CIRCLE_STATE_KINDS } from "../../conformance/src/envelope.ts";
import { HEADER_KEY } from "../../conformance/src/request.ts";
import { authenticateWith, spendNonce, verifyRequest } from "./auth.ts";
import { ENVELOPE_COLUMNS, KEY_COLUMNS, keyJson, keyStateOf, storedOf, type EnvelopeRow, type KeyRow } from "./db.ts";
import type { Relay } from "./env.ts";
import { empty, json, Refusal } from "./errors.ts";
import { RELAY_VERSION, relayVersionField } from "./version.ts";

function integer(value: string | null, fallback: number): number {
  if (value === null || value === "") return fallback;
  const n = Number(value);
  return Number.isInteger(n) ? n : fallback;
}

const CIRCLE_STATE_IN = CIRCLE_STATE_KINDS.map((k) => `'${k}'`).join(", ");
const PAGE_SQL = `SELECT ${ENVELOPE_COLUMNS} FROM envelopes WHERE relay_id > ? AND (kind IN (${CIRCLE_STATE_IN}) OR epoch >= ?) ORDER BY relay_id LIMIT ?`;

/**
 * Everything after a cursor in relay_id order: circle state in full, content from the reader's join
 * epoch on. Two round trips: the reader's key, then the nonce and the page in one batch.
 */
export async function page(relay: Relay, request: Request, url: URL): Promise<Response> {
  const after = Math.max(0, integer(url.searchParams.get("after"), 0));
  const limit = Math.max(1, Math.min(integer(url.searchParams.get("limit"), relay.limits.max_page_size), relay.limits.max_page_size));
  const { results } = await authenticateWith(relay, request, url, "", (reader) => [relay.db.prepare(PAGE_SQL).bind(after, reader.join_epoch, limit + 1)]);
  const read = (results[0]?.results ?? []) as EnvelopeRow[];
  const rows = read.slice(0, limit);
  const last = rows[rows.length - 1];
  const more = read.length > limit && last !== undefined;
  return json(200, { envelopes: rows.map(storedOf), ...(more ? { next: last.relay_id } : {}) });
}

/**
 * The root, the epoch, the admission cutover, the admitted keys, the limits and the stamped
 * relay_version (none when unstamped), to an admitted reader. Two round trips, as page.
 */
export async function circle(relay: Relay, request: Request, url: URL): Promise<Response> {
  const { results } = await authenticateWith(relay, request, url, "", () => [
    relay.db.prepare(`SELECT ${KEY_COLUMNS} FROM admitted_keys ORDER BY key`),
    relay.db.prepare("SELECT epoch, admission_cutover FROM circle WHERE id = 1"),
  ]);
  const keys = ((results[0]?.results ?? []) as KeyRow[]).map(keyStateOf).map((state) => {
    const { mail_read: _mailRead, ...reported } = keyJson(state) as { [key: string]: unknown };
    return reported;
  });
  const row = results[1]?.results[0] as { epoch: number; admission_cutover: number } | undefined;
  return json(200, {
    root: relay.root,
    epoch: row?.epoch ?? 0,
    admission_cutover: row?.admission_cutover ?? 0,
    keys,
    limits: relay.limits,
    ...relayVersionField(RELAY_VERSION),
  });
}

/**
 * The bootstrap read: the dinner listing an open invite, to the invite key alone. An unknown, spent
 * or expired invite is 404 with no body, one answer for all three; another signer is 401.
 */
export async function invite(relay: Relay, request: Request, url: URL, inviteKey: string): Promise<Response> {
  if (request.headers.get(HEADER_KEY) !== inviteKey) throw new Refusal(401, "not_admitted", "the bootstrap read is signed by the invite key it names");
  const verified = verifyRequest(relay, request, url, "");
  const row = await relay.db.prepare("SELECT dinner, expires_at, spent FROM invites WHERE key = ?").bind(inviteKey).first<{ dinner: string; expires_at: string; spent: number }>();
  if (row === null || row.spent !== 0 || Date.parse(row.expires_at) <= relay.now.getTime()) return empty(404);
  // The nonce is spent only for an open invite, so a key no dinner lists writes nothing. DIG-228
  const [found] = await spendNonce(relay, verified, [relay.db.prepare(`SELECT ${ENVELOPE_COLUMNS} FROM envelopes WHERE hash = ?`).bind(row.dinner)]);
  const dinner = found?.results[0] as EnvelopeRow | undefined;
  if (dinner === undefined) return empty(404);
  return json(200, storedOf(dinner));
}
