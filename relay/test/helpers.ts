// What the mailer tests share: the suite's World routed to the Worker under test, a fake Resend
// endpoint standing in for the real one, and the node's half of a digest (an ask, pre-signed
// decisions, sealed answer links) written with the suite's signers and node/mail/webcrypto/mail.mjs.
import { SELF } from "cloudflare:test";
import { b64url, jcs, type Json } from "../../conformance/src/encoding.ts";
import { envelopeHash, signEnvelope, type Author, type SignedEnvelope } from "../../conformance/src/envelope.ts";
import type { Signer } from "../../conformance/src/keys.ts";
import type { World } from "../../conformance/src/world.ts";
import { decisionBody, seal, unb64url } from "../../node/mail/webcrypto/mail.mjs";
import { RESEND_URL } from "../src/env.ts";

export const RELAY = "http://relay.test";

export interface SentMail {
  authorization: string | null;
  body: { from: string; to: string[]; subject: string; text: string; html: string };
}

/** The fake Resend endpoint: every send the Worker makes lands here, and nothing leaves the isolate. */
export class FakeResend {
  readonly sent: SentMail[] = [];
  /** The status the next sends answer. */
  status = 200;
  private readonly realFetch = globalThis.fetch;

  /** Routes the suite's client to the Worker and the Worker's sends here; anything else is refused. */
  install(): void {
    globalThis.fetch = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
      const request = input instanceof Request ? input : new Request(input, init);
      if (request.url.startsWith(RELAY)) return SELF.fetch(request.url, init ?? request);
      if (request.url === RESEND_URL) {
        this.sent.push({ authorization: request.headers.get("authorization"), body: await request.json<SentMail["body"]>() });
        return new Response(JSON.stringify(this.status < 300 ? { id: `fake-${this.sent.length}` } : { message: "fake failure" }), {
          status: this.status,
          headers: { "content-type": "application/json" },
        });
      }
      throw new Error(`the tests reach nothing outside the isolate: ${request.method} ${request.url}`);
    };
  }

  uninstall(): void {
    globalThis.fetch = this.realFetch;
  }
}

const enc = new TextEncoder();

/** The node's half of docs/protocol.md "Answer links": seal a payload under a link id and secret so openLink opens it. */
export async function sealLink(idText: string, secretText: string, payload: Json): Promise<string> {
  const id = unb64url(idText);
  const ikm = await crypto.subtle.importKey("raw", unb64url(secretText), "HKDF", false, ["deriveBits"]);
  const key = new Uint8Array(await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt: id, info: enc.encode("digestif-v0 link") }, ikm, 256));
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const aes = await crypto.subtle.importKey("raw", key, "AES-GCM", false, ["encrypt"]);
  const ciphertext = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: enc.encode(`digestif-v0 link ${idText}`) }, aes, enc.encode(jcs(payload))));
  const out = new Uint8Array(12 + ciphertext.length);
  out.set(nonce);
  out.set(ciphertext, 12);
  return b64url(out);
}

export interface Option {
  id: string;
  label: string;
  recommended?: boolean;
}

export interface AskSpec {
  title: string;
  detail: string;
  options: Option[];
  on_no_answer: string;
  lapses_at: string;
  kind?: string;
}

export interface Link {
  id: string;
  secret: string;
  ask: string;
  label: string;
}

export interface Digest {
  signed: SignedEnvelope;
  hash: string;
  links: Link[];
  plaintext: { to: string; subject: string; sections: Json; asks: Json };
}

export interface DigestOptions {
  /** The key that pre-signs the decisions: the member's mail key unless a case uses another. */
  mailKey: Author | Signer;
  /** A decision's prev: the ask's hash unless a case points it elsewhere. */
  prevOf?: (askHash: string) => string;
  /** The seq each decision takes: the mail key's counter unless a case reuses one. */
  seqOf?: () => number;
  to?: string;
  subject?: string;
  sections?: { title: string; lines: string[] }[];
  /** The recipients the email is sealed to: the member's key and the relay's unless a case seals it wrongly. */
  recipients?: Uint8Array<ArrayBuffer>[];
}

/** The node's digest for a set of asks: one pre-signed decision and one sealed link per option. */
export class Node {
  private mailSeq = 0;

  constructor(
    readonly world: World,
    readonly device: Author,
    readonly memberKey: Uint8Array<ArrayBuffer>,
    readonly relayKey: Uint8Array<ArrayBuffer>,
  ) {}

  nextMailSeq(): number {
    this.mailSeq += 1;
    return this.mailSeq;
  }

  /** Appends an ask sealed to the member's own key; returns its hash. */
  async ask(spec: AskSpec): Promise<string> {
    const { kind: _kind, ...plaintext } = spec;
    const body = { sealed: (await seal([this.memberKey], { ...plaintext, kind: spec.kind ?? "intro" })) as unknown as Json };
    const signed = await this.world.post(this.device, "", [RELAY], "ask", body);
    return envelopeHash(signed.envelope);
  }

  async digest(asks: Array<{ hash: string; spec: AskSpec }>, options: DigestOptions): Promise<Digest> {
    const epoch = await this.world.epoch(RELAY);
    const signer = "signer" in options.mailKey ? options.mailKey.signer : options.mailKey;
    const links: Link[] = [];
    const records: Json[] = [];
    const emailAsks: Json[] = [];
    for (const { hash, spec } of asks) {
      const rendered: Json[] = [];
      for (const option of spec.options) {
        const body = (await decisionBody(this.memberKey, hash, option.id)) as unknown as Json;
        const decision = signEnvelope(signer, {
          kind: "decision",
          body,
          seq: options.seqOf === undefined ? this.nextMailSeq() : options.seqOf(),
          prev: options.prevOf === undefined ? hash : options.prevOf(hash),
          epoch,
        });
        const id = b64url(crypto.getRandomValues(new Uint8Array(16)));
        const secret = b64url(crypto.getRandomValues(new Uint8Array(32)));
        const sealedAnswer = await sealLink(id, secret, { ask_title: spec.title, label: option.label, signed: decision as unknown as Json });
        links.push({ id, secret, ask: hash, label: option.label });
        records.push({ id, ask: hash, expires_at: spec.lapses_at, sealed_answer: sealedAnswer });
        rendered.push({ label: option.label, ...(option.recommended ? { recommended: true } : {}), link: id });
      }
      emailAsks.push({ ask: hash, title: spec.title, detail: spec.detail, on_no_answer: spec.on_no_answer, lapses_at: spec.lapses_at, options: rendered });
    }
    const plaintext = {
      to: options.to ?? "mike@example.com",
      subject: options.subject ?? "Digestif, October 29: 3 in, 1 out, 1 ask",
      sections: options.sections ?? [{ title: "Came in", lines: ["Roman (Ada): shipped the D1 fold."] }],
      asks: emailAsks,
    };
    const sealed = (await seal(options.recipients ?? [this.memberKey, this.relayKey], plaintext)) as unknown as Json;
    const body: Json = { date: "2026-10-29", sealed, links: records };
    const signed = this.device.next("digest", body, epoch);
    await this.world.publish([RELAY], this.device, signed);
    return { signed, hash: envelopeHash(signed.envelope), links, plaintext };
  }

  /** The mail request's body: the link secrets sealed to the relay (or, for a case, to another key). */
  async mailRequest(digest: Digest, sealTo: Uint8Array<ArrayBuffer> = this.relayKey): Promise<string> {
    const sealed = (await seal([sealTo], { links: digest.links.map((l) => ({ id: l.id, secret: l.secret })) })) as unknown as Json;
    return jcs({ digest: digest.hash, sealed });
  }
}

/** Every row of every table, as one string: what a test searches for a secret or a plaintext. */
export async function dumpTables(db: D1Database): Promise<string> {
  const { results } = await db.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").all<{ name: string }>();
  const dump: Record<string, unknown[]> = {};
  for (const { name } of results) {
    if (name.startsWith("sqlite_") || name.startsWith("_cf") || name.startsWith("d1_")) continue;
    dump[name] = (await db.prepare(`SELECT * FROM "${name}"`).all()).results;
  }
  return JSON.stringify(dump);
}

export async function countRows(db: D1Database, table: string, where = "1 = 1", ...binds: unknown[]): Promise<number> {
  const row = await db.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE ${where}`).bind(...binds).first<{ n: number }>();
  return row?.n ?? 0;
}
