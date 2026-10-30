// POST /v0/mail, docs/protocol.md "Mailer routes": open the mail request and the digest with the
// relay's sealing key, render the email with every option's link URL in it, send it through
// Resend, and remember the digest hash so a repeat mails nothing. The request, the secrets and
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

/** The link index of a digest body: id, ask and expiry per link (docs/protocol.md "The digest"). */
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
  // authenticate admitted the signer; it must be a device key of the digest author's identity.
  const signer = auth.key === undefined ? undefined : await loadKey(relay.db, auth.key);
  const author = await loadKey(relay.db, digest.author);
  if (signer === undefined || author === undefined || signer.role !== "device" || signer.identity !== author.identity) {
    throw new Refusal(401, "not_admitted", "a mail request is signed by a device key of the digest's author");
  }
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

  const base = mailer.url ?? url.origin;
  const email = renderEmail(plaintext, (id) => linkUrl(base, id, secrets.get(id) ?? ""));

  // The claim goes in before the send, with the link index: a lost race finds the row and mails
  // nothing. The batch is one transaction.
  const db = relay.db;
  const now = isoTime(relay.now);
  const [claim] = await db.batch([
    db.prepare("INSERT OR IGNORE INTO mailed_digests (digest, sent_at) VALUES (?, ?)").bind(digest.hash, now),
    ...links.map((link) => db.prepare("INSERT OR IGNORE INTO links (id, digest, ask, expires_at) VALUES (?, ?, ?, ?)").bind(link.id, digest.hash, link.ask, link.expires_at)),
  ]);
  if (claim === undefined || claim.meta.changes === 0) return json(200, { status: "already_sent", digest: digest.hash });

  const failure = await send(mailer, plaintext.to, email);
  if (failure !== undefined) {
    await db.batch([
      db.prepare("DELETE FROM mailed_digests WHERE digest = ?").bind(digest.hash),
      db.prepare("DELETE FROM links WHERE digest = ?").bind(digest.hash),
    ]);
    throw new Refusal(502, "mail_failed", failure);
  }
  return json(202, { status: "sent", digest: digest.hash });
}

/** One POST to Resend; the failure as text, or undefined when the mail was accepted. */
async function send(mailer: Mailer, to: string, email: Email): Promise<string | undefined> {
  let response: Response;
  try {
    response = await fetch(RESEND_URL, {
      method: "POST",
      headers: { authorization: `Bearer ${mailer.resendKey}`, "content-type": "application/json" },
      body: JSON.stringify({ from: mailer.from, to: [to], subject: email.subject, text: email.text, html: email.html }),
    });
  } catch (error) {
    return `the mail service could not be reached: ${error instanceof Error ? error.message : String(error)}`;
  }
  if (response.ok) return undefined;
  return `the mail service answered ${response.status}`;
}
