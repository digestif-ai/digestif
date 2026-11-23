// POST /v0/mail, docs/protocol.md "Mailer routes": open the mail request and the digest with the
// relay's sealing key, render the email with every option's link URL in it, send it through
// Resend under the digest's idempotency key, and remember the digest hash once Resend accepted it
// so a repeat mails nothing. The request, the secrets and
// the plaintext are read, used and dropped: nothing here writes them anywhere.
import { isoTime, type Json } from "../../conformance/src/encoding.ts";
import { linkUrl, openSealed, type Sealed } from "../../node/mail/webcrypto/mail.mjs";
import { authenticate } from "./auth.ts";
import { loadEnvelope, loadKey } from "./db.ts";
import { RESEND_URL, type Mailer, type Relay } from "./env.ts";
import { json, Refusal } from "./errors.ts";
import { linkIds, parseDigestPlaintext, renderEmail, type Email } from "./render.ts";

function isObject(value: unknown): value is { [key: string]: Json } {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** A sealed value's shape (docs/protocol.md "Sealing"); opening it is the real check. */
function isSealed(value: unknown): value is Sealed {
  return (
    isObject(value) &&
    typeof value["alg"] === "string" &&
    Array.isArray(value["recipients"]) &&
    typeof value["nonce"] === "string" &&
    typeof value["ciphertext"] === "string"
  );
}

interface MailRequest {
  digest: string;
  sealed: Sealed;
}

function parseMailRequest(raw: string): MailRequest {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new Refusal(422, "malformed", "the body is not JSON");
  }
  if (!isObject(value) || typeof value["digest"] !== "string" || !isSealed(value["sealed"])) {
    throw new Refusal(422, "malformed", "a mail request is { digest, sealed }");
  }
  return { digest: value["digest"], sealed: value["sealed"] };
}

/** Opens a value sealed to the relay's key, or `422 malformed` naming what could not be opened. */
export async function openOrRefuse(mailer: Mailer, sealed: unknown, what: string): Promise<Json> {
  if (!isSealed(sealed)) throw new Refusal(422, "malformed", `${what} is not a sealed value`);
  try {
    return await openSealed(mailer.sealing.privateKey, mailer.sealing.publicRaw, sealed);
  } catch {
    throw new Refusal(422, "malformed", `${what} is not sealed to this relay's key`);
  }
}

/** The link index of a digest body: id, the item it answers (under `ask`) and expiry per link (docs/protocol.md "The digest"). */
export interface DigestLink {
  id: string;
  ask: string;
  expires_at: string;
  sealed_answer: string;
}

export function digestLinks(body: Json): DigestLink[] {
  if (!isObject(body) || !Array.isArray(body["links"])) throw new Refusal(422, "malformed", "the digest body has no links");
  return body["links"].map((link) => {
    if (
      !isObject(link) ||
      typeof link["id"] !== "string" ||
      typeof link["ask"] !== "string" ||
      typeof link["expires_at"] !== "string" ||
      typeof link["sealed_answer"] !== "string"
    ) {
      throw new Refusal(422, "malformed", "a digest link is { id, ask, expires_at, sealed_answer }");
    }
    return { id: link["id"], ask: link["ask"], expires_at: link["expires_at"], sealed_answer: link["sealed_answer"] };
  });
}

/** The secrets of the mail request's plaintext, by link id. */
function secretsOf(plaintext: Json): Map<string, string> {
  if (!isObject(plaintext) || !Array.isArray(plaintext["links"])) throw new Refusal(422, "malformed", "the mail request's plaintext is { links: [ { id, secret } ] }");
  const secrets = new Map<string, string>();
  for (const link of plaintext["links"]) {
    if (!isObject(link) || typeof link["id"] !== "string" || typeof link["secret"] !== "string") {
      throw new Refusal(422, "malformed", "a mail request link is { id, secret }");
    }
    secrets.set(link["id"], link["secret"]);
  }
  return secrets;
}

export async function mail(relay: Relay, mailer: Mailer, request: Request, url: URL): Promise<Response> {
  const raw = await request.text();
  const auth = await authenticate(relay, request, url, raw);
  const parsed = parseMailRequest(raw);
  const digest = await loadEnvelope(relay.db, parsed.digest);
  if (digest === undefined || digest.kind !== "digest" || digest.body === null) {
    throw new Refusal(404, "unknown_digest", `this relay holds no digest ${parsed.digest}`);
  }
  // authenticate admitted the signer; it must be a device key of the digest author's identity. A digest
  // another identity wrote is answered as one the relay does not hold (spec: unknown_digest covers
  // "one the requester's identity did not write"), so the route says nothing about digests the caller
  // does not own; a mail key of the right identity is refused at the request layer instead.
  const signer = auth.state;
  const author = await loadKey(relay.db, digest.author);
  if (signer === undefined || author === undefined || signer.identity !== author.identity) {
    throw new Refusal(404, "unknown_digest", `this relay holds no digest ${parsed.digest}`);
  }
  if (signer.role !== "device") throw new Refusal(401, "not_admitted", "a mail request is signed by a device key of the digest's author");
  const secrets = secretsOf(await openOrRefuse(mailer, parsed.sealed, "the mail request"));
  const body = JSON.parse(digest.body) as Json;
  const links = digestLinks(body);
  let plaintext;
  try {
    plaintext = parseDigestPlaintext(await openOrRefuse(mailer, isObject(body) ? body["sealed"] : undefined, "the digest"));
  } catch (error) {
    if (error instanceof Refusal) throw error;
    throw new Refusal(422, "malformed", `the digest plaintext does not parse: ${error instanceof Error ? error.message : String(error)}`);
  }
  const held = new Set(links.map((link) => link.id));
  for (const id of linkIds(plaintext)) {
    if (!held.has(id)) throw new Refusal(422, "malformed", `the digest carries no link ${id}`);
    if (!secrets.has(id)) throw new Refusal(422, "malformed", `the mail request carries no secret for link ${id}`);
  }
  const already = await relay.db.prepare("SELECT 1 AS held FROM mailed_digests WHERE digest = ?").bind(digest.hash).first();
  if (already !== null) return json(200, { status: "already_sent", digest: digest.hash });
  await checkDailyMail(relay, author.identity);

  // Answer links name the circle's own address, so a member of two circles on one relay answers each in its own.
  const email = forCircle(renderEmail(plaintext, (id) => linkUrl(relay.address, id, secrets.get(id) ?? "")), await circleName(relay));
  const from = fromFor(mailer.from, await circleName(relay));

  // A lease on the digest goes in before the send, with the link index; mailed_digests is written
  // only once Resend has accepted the mail. A request that finds a live lease mails nothing and is
  // told to come back (the node keeps its request on anything but sent and already_sent). A lease
  // whose Worker died mid-send expires, and the next request takes it over and sends again under
  // the same Resend idempotency key, so a mail that did go is not sent twice.
  const db = relay.db;
  const now = isoTime(relay.now);
  const holder = crypto.randomUUID();
  const until = isoTime(new Date(relay.now.getTime() + MAIL_LEASE_MS));
  const [claim] = await db.batch([
    db
      .prepare(
        "INSERT INTO mail_claims (digest, holder, claimed_until) SELECT ?1, ?2, ?3 " +
          "WHERE NOT EXISTS (SELECT 1 FROM mailed_digests WHERE digest = ?1) " +
          "ON CONFLICT (digest) DO UPDATE SET holder = excluded.holder, claimed_until = excluded.claimed_until " +
          "WHERE mail_claims.claimed_until <= ?4",
      )
      .bind(digest.hash, holder, until, now),
    ...links.map((link) => db.prepare("INSERT OR IGNORE INTO links (id, digest, ask, expires_at) VALUES (?, ?, ?, ?)").bind(link.id, digest.hash, link.ask, link.expires_at)),
  ]);
  if (claim === undefined || claim.meta.changes === 0) {
    const sent = await db.prepare("SELECT 1 AS held FROM mailed_digests WHERE digest = ?").bind(digest.hash).first();
    if (sent !== null) return json(200, { status: "already_sent", digest: digest.hash });
    throw new Refusal(503, "mail_failed", `a send of digest ${digest.hash} is in flight; try again later`);
  }

  const failure = await send(mailer, from, plaintext.to, email, digest.hash);
  if (failure !== undefined) {
    // Only this request's own lease is dropped, and the link index with it unless another request
    // has since taken the lease or recorded the digest mailed.
    await db.batch([
      db.prepare("DELETE FROM mail_claims WHERE digest = ? AND holder = ?").bind(digest.hash, holder),
      db
        .prepare(
          "DELETE FROM links WHERE digest = ? AND NOT EXISTS (SELECT 1 FROM mail_claims WHERE digest = ?) " +
            "AND NOT EXISTS (SELECT 1 FROM mailed_digests WHERE digest = ?)",
        )
        .bind(digest.hash, digest.hash, digest.hash),
    ]);
    throw new Refusal(502, "mail_failed", failure);
  }
  await db.batch([
    db.prepare("INSERT OR IGNORE INTO mailed_digests (digest, sent_at) VALUES (?, ?)").bind(digest.hash, isoTime(new Date())),
    db.prepare("DELETE FROM mail_claims WHERE digest = ?").bind(digest.hash),
  ]);
  return json(202, { status: "sent", digest: digest.hash });
}

/**
 * Digests one member is mailed per circle per day. A node mails one a day, so only a runaway node
 * reaches it, and it cannot spend the mail provider's daily quota every other circle shares.
 */
export const MAIL_DIGESTS_PER_DAY = 2;

/** Counts the digests by any key of [identity] this circle mailed since midnight UTC, and refuses one past the cap. */
async function checkDailyMail(relay: Relay, identity: string): Promise<void> {
  const midnight = `${isoTime(relay.now).slice(0, 10)}T00:00:00`;
  const row = await relay.db
    .prepare(
      "SELECT COUNT(*) AS n FROM mailed_digests m JOIN envelopes e ON e.hash = m.digest JOIN admitted_keys k ON k.key = e.author " +
        "WHERE k.identity = ? AND m.sent_at >= ?",
    )
    .bind(identity, midnight)
    .first<{ n: number }>();
  if ((row?.n ?? 0) >= MAIL_DIGESTS_PER_DAY) {
    throw new Refusal(429, "rate_limited", `this member was mailed ${MAIL_DIGESTS_PER_DAY} digests of this circle today; the next mails tomorrow (UTC)`);
  }
}

/**
 * The circle's name, from its root: a circle root names it. A circle founded at a dinner, which
 * predates circle names, has none, and its mail reads as it always has.
 */
async function circleName(relay: Relay): Promise<string | undefined> {
  const root = await loadEnvelope(relay.db, relay.root);
  if (root === undefined || root.kind !== "circle" || root.body === null) return undefined;
  const body = JSON.parse(root.body) as Json;
  const circle = isObject(body) ? body["circle"] : undefined;
  const name = isObject(circle) ? circle["name"] : undefined;
  if (typeof name !== "string") return undefined;
  // A header value: no line breaks, no quotes or angle brackets to end the display name early.
  const clean = name.replace(/[\r\n"<>\\]/g, " ").replace(/\s+/g, " ").trim();
  return clean === "" ? undefined : clean;
}

/** The From header naming the circle: its name as the display name, the relay's own address. */
export function fromFor(configured: string, name: string | undefined): string {
  if (name === undefined) return configured;
  const address = /<([^>]+)>\s*$/.exec(configured)?.[1] ?? configured.trim();
  return `"${name} (Digestif)" <${address}>`;
}

/** The subject with the circle's name in front, so a member of two circles tells their digests apart. */
export function forCircle(email: Email, name: string | undefined): Email {
  if (name === undefined || email.subject.startsWith(name)) return email;
  return { ...email, subject: `${name}: ${email.subject}` };
}

/** How long a send holds its lease on a digest: far longer than one call to Resend takes. */
export const MAIL_LEASE_MS = 2 * 60 * 1000;

/** The Resend idempotency key of a digest's mail: a retry under it is answered, not sent again. */
export function mailIdempotencyKey(digest: string): string {
  return `digestif-mail/${digest}`;
}

/** One POST to Resend; the failure as text, or undefined when the mail was accepted. */
async function send(mailer: Mailer, from: string, to: string, email: Email, digest: string): Promise<string | undefined> {
  let response: Response;
  try {
    response = await fetch(RESEND_URL, {
      method: "POST",
      headers: {
        authorization: `Bearer ${mailer.resendKey}`,
        "content-type": "application/json",
        "idempotency-key": mailIdempotencyKey(digest),
      },
      body: JSON.stringify({ from, to: [to], subject: email.subject, text: email.text, html: email.html }),
    });
  } catch (error) {
    return `the mail service could not be reached: ${error instanceof Error ? error.message : String(error)}`;
  }
  if (response.ok) return undefined;
  return `the mail service answered ${response.status}`;
}
