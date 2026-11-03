// GET and POST /v0/links/:id, docs/protocol.md "Mailer routes" and "Answer links". The link index
// (the `links` table, written when the digest was mailed) names the digest whose body holds the
// sealed answer; the secret in the URL opens it. GET changes nothing; POST appends the decision
// through the core append path and marks every link of the ask used.
import { jcs, type Json } from "../../conformance/src/encoding.ts";
import { checkAnswer, openLink } from "../../node/mail/webcrypto/mail.mjs";
import { appendSigned, checkSize, parseSigned } from "./append.ts";
import { loadEnvelope, loadKey } from "./db.ts";
import type { Relay } from "./env.ts";
import { Refusal } from "./errors.ts";
import { digestLinks } from "./mail.ts";
import { confirmPage, donePage, refusedPage, troublePage } from "./pages.ts";

interface LinkRow {
  id: string;
  digest: string;
  ask: string;
  expires_at: string;
  used_at: string | null;
}

interface Opened {
  row: LinkRow;
  /** The digest's author key: the identity whose mail keys may have signed the answer. */
  author: string;
  askTitle: string;
  label: string;
  /** The node's sentence for the confirm page under this answer, when it acts later than the click. */
  note: string | undefined;
  signed: Parameters<typeof checkAnswer>[0]["signed"];
}

/**
 * The link by id, its sealed answer opened with the secret. The checks run in this order: unknown,
 * then the secret, then used, then closed, then expired, so a page never says more about a link
 * than its secret earns.
 */
async function open(relay: Relay, id: string, secret: string | null): Promise<Opened | Response> {
  const row = await relay.db.prepare("SELECT id, digest, ask, expires_at, used_at FROM links WHERE id = ?").bind(id).first<LinkRow>();
  if (row === null) return troublePage("unknown");
  const digest = await loadEnvelope(relay.db, row.digest);
  if (digest === undefined || digest.body === null) return troublePage("unknown");
  const link = digestLinks(JSON.parse(digest.body) as Json).find((l) => l.id === id);
  if (link === undefined) return troublePage("unknown");
  if (secret === null || secret === "") return troublePage("wrong_secret");
  let payload;
  try {
    payload = await openLink(id, secret, link.sealed_answer);
  } catch {
    return troublePage("wrong_secret");
  }
  if (!isPayload(payload)) return troublePage("wrong_secret");
  if (row.used_at !== null) return troublePage("used");
  if (await answeredElsewhere(relay, digest.author, row.ask)) return troublePage("closed");
  if (Date.parse(row.expires_at) <= relay.now.getTime()) return troublePage("expired");
  return {
    row,
    author: digest.author,
    askTitle: payload.ask_title,
    label: payload.label,
    note: typeof payload.note === "string" ? payload.note : undefined,
    signed: payload.signed,
  };
}

/**
 * Whether the relay holds a decision on [ask] by any key of the identity [author] belongs to: the
 * member answered it on their machine or their phone, or the machine closed it (docs/protocol.md,
 * Asks and decisions), so no link answers it any more.
 */
async function answeredElsewhere(relay: Relay, author: string, ask: string): Promise<boolean> {
  const hit = await relay.db
    .prepare(
      "SELECT 1 AS hit FROM envelopes e JOIN admitted_keys k ON k.key = e.author " +
        "WHERE e.kind = 'decision' AND e.body IS NOT NULL AND json_extract(e.body, '$.ask') = ? " +
        "AND k.identity = (SELECT identity FROM admitted_keys WHERE key = ?) LIMIT 1",
    )
    .bind(ask, author)
    .first<{ hit: number }>();
  return hit !== null;
}

function isPayload(value: unknown): value is { ask_title: string; label: string; note?: unknown; signed: Opened["signed"] } {
  if (typeof value !== "object" || value === null) return false;
  const p = value as { ask_title?: unknown; label?: unknown; signed?: unknown };
  return typeof p.ask_title === "string" && typeof p.label === "string" && typeof p.signed === "object" && p.signed !== null;
}

/** GET: the confirm page. Nothing is written. */
export async function linkPage(relay: Relay, _request: Request, url: URL, id: string): Promise<Response> {
  const opened = await open(relay, id, url.searchParams.get("s"));
  if (opened instanceof Response) return opened;
  return confirmPage(opened.askTitle, opened.label, url.pathname, url.searchParams.get("s") ?? "", opened.note);
}

/** The admitted, unrevoked mail keys of the identity a key belongs to. */
async function mailKeysOf(relay: Relay, key: string): Promise<string[]> {
  const state = await loadKey(relay.db, key);
  if (state === undefined) return [];
  const { results } = await relay.db
    .prepare("SELECT key FROM admitted_keys WHERE identity = ? AND role = 'mail' AND revoked_at IS NULL")
    .bind(state.identity)
    .all<{ key: string }>();
  return results.map((r) => r.key);
}

/** POST: check the pre-signed decision, append it, mark the ask's links used, and say so. */
export async function confirmLink(relay: Relay, request: Request, _url: URL, id: string): Promise<Response> {
  const form = new URLSearchParams(new TextDecoder().decode(await request.arrayBuffer()));
  const opened = await open(relay, id, form.get("s"));
  if (opened instanceof Response) return opened;
  try {
    await checkAnswer({ signed: opened.signed }, { mailKeys: await mailKeysOf(relay, opened.author), ask: opened.row.ask });
  } catch (error) {
    return refusedPage(error instanceof Error ? error.message : String(error));
  }
  const raw = jcs(opened.signed);
  const usedAt = relay.now.toISOString();
  let receipt;
  try {
    checkSize(relay, new TextEncoder().encode(raw).byteLength);
    // Every link of the ask is marked used in the append's own batch; the links_single_use trigger
    // (migrations/0002_mailer.sql) aborts it when another link of the ask got there first.
    receipt = await appendSigned(relay, { key: undefined }, parseSigned(raw), (db) => [
      db.prepare("UPDATE links SET used_at = ? WHERE ask = ?").bind(usedAt, opened.row.ask),
    ]);
  } catch (error) {
    if (isLinkUsed(error)) return troublePage("used");
    if (!(error instanceof Refusal)) throw error;
    return refusedPage(`${error.code}, ${error.message}`);
  }
  if (receipt.status === "duplicate") {
    // This very decision is already in the log (the same link confirmed twice at once): the ask is answered.
    await relay.db.prepare("UPDATE links SET used_at = ? WHERE ask = ? AND used_at IS NULL").bind(usedAt, opened.row.ask).run();
  }
  return donePage(opened.askTitle, opened.label, opened.note);
}

/** The links_single_use trigger's abort, as D1 reports it. */
function isLinkUsed(error: unknown): boolean {
  return error instanceof Error && /link_used/.test(error.message);
}
