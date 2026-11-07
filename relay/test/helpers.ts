// What the mailer tests share: the suite's World routed to the Worker under test, a fake Resend
// endpoint standing in for the real one, and the node's half of a digest (a choice, pre-signed
// decisions, sealed answer links) written with the suite's signers and node/mail/webcrypto/mail.mjs.
import { SELF } from "cloudflare:test";
import { b64url, jcs, type Json } from "../../conformance/src/encoding.ts";
import { envelopeHash, signEnvelope, type Author, type SignedEnvelope } from "../../conformance/src/envelope.ts";
import type { Signer } from "../../conformance/src/keys.ts";
import type { Member, World } from "../../conformance/src/world.ts";
import { seal, unb64url } from "../../node/mail/webcrypto/mail.mjs";
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
  /** The node's sentence for the confirm page under this answer. */
  note?: string;
}

/** A choice addressed to the member alone (docs/protocol.md, Items): what the node seals and the digest carries. */
export interface ChoiceSpec {
  title: string;
  detail: string;
  options: Option[];
  /** The option id that stands with no pick. */
  default: string;
  deadline: string;
  subject?: string;
}

export interface Link {
  id: string;
  secret: string;
  item: string;
  label: string;
}

export interface Digest {
  signed: SignedEnvelope;
  hash: string;
  links: Link[];
  plaintext: { to: string; subject: string; sections: Json; inbox: Json };
}

export interface DigestOptions {
  /** The key that pre-signs the decisions: the member's mail key unless a case uses another. */
  mailKey: Author | Signer;
  /** A decision's prev: the choice's hash unless a case points it elsewhere. */
  prevOf?: (itemHash: string) => string;
  /** The seq each decision takes: the mail key's counter unless a case reuses one. */
  seqOf?: () => number;
  to?: string;
  subject?: string;
  sections?: { title: string; lines: string[] }[];
  /** The recipients the email is sealed to: the member's key and the relay's unless a case seals it wrongly. */
  recipients?: Uint8Array<ArrayBuffer>[];
}

/** A pick on [item] (docs/protocol.md, Items, Picks): the option sealed to the member's own key. */
async function pickBody(memberKey: Uint8Array<ArrayBuffer>, item: string, option: string): Promise<Json> {
  return { item, sealed: (await seal([memberKey], { option })) as unknown as Json };
}

/** The node's digest for a set of choices: one pre-signed decision and one sealed link per option. */
export class Node {
  private mailSeq = 0;
  readonly device: Author;

  constructor(
    readonly world: World,
    readonly member: Member,
    readonly memberKey: Uint8Array<ArrayBuffer>,
    readonly relayKey: Uint8Array<ArrayBuffer>,
  ) {
    this.device = member.device;
  }

  nextMailSeq(): number {
    this.mailSeq += 1;
    return this.mailSeq;
  }

  /** Appends a choice item addressed to the member alone and sealed to their own key; returns its hash. */
  async choice(spec: ChoiceSpec): Promise<string> {
    const item = {
      kind: "choice",
      subject: spec.subject ?? "behavior",
      voice: "node",
      title: spec.title,
      detail: spec.detail,
      options: spec.options.map((o) => ({ id: o.id, label: o.label, ...(o.recommended ? { recommended: true } : {}) })),
      default: spec.default,
      deadline: spec.deadline,
    };
    const body = { to: [this.member.identity.key], sealed: (await seal([this.memberKey], item)) as unknown as Json };
    const signed = await this.world.post(this.device, "", [RELAY], "item", body);
    return envelopeHash(signed.envelope);
  }

  /** Appends this member's device decision on [itemHash], as the machine or a phone writes one. */
  async decide(itemHash: string, option: string): Promise<void> {
    await this.world.post(this.device, "", [RELAY], "decision", await pickBody(this.memberKey, itemHash, option));
  }

  async digest(choices: Array<{ hash: string; spec: ChoiceSpec }>, options: DigestOptions): Promise<Digest> {
    const epoch = await this.world.epoch(RELAY);
    const signer = "signer" in options.mailKey ? options.mailKey.signer : options.mailKey;
    const links: Link[] = [];
    const records: Json[] = [];
    const inbox: Json[] = [];
    for (const { hash, spec } of choices) {
      const rendered: Json[] = [];
      for (const option of spec.options) {
        const decision = signEnvelope(signer, {
          kind: "decision",
          body: await pickBody(this.memberKey, hash, option.id),
          seq: options.seqOf === undefined ? this.nextMailSeq() : options.seqOf(),
          prev: options.prevOf === undefined ? hash : options.prevOf(hash),
          epoch,
        });
        const id = b64url(crypto.getRandomValues(new Uint8Array(16)));
        const secret = b64url(crypto.getRandomValues(new Uint8Array(32)));
        const sealedAnswer = await sealLink(id, secret, {
          ask_title: spec.title,
          label: option.label,
          signed: decision as unknown as Json,
          ...(option.note === undefined ? {} : { note: option.note }),
        });
        links.push({ id, secret, item: hash, label: option.label });
        // The link record names the item it answers under `ask` (docs/protocol.md "Answer links").
        records.push({ id, ask: hash, expires_at: spec.deadline, sealed_answer: sealedAnswer });
        rendered.push({ id: option.id, label: option.label, ...(option.recommended ? { recommended: true } : {}), link: id });
      }
      inbox.push({ item: hash, kind: "choice", title: spec.title, line: "Choice from your node", default: spec.default, deadline: spec.deadline, options: rendered });
    }
    const plaintext = {
      to: options.to ?? "mike@example.com",
      subject: options.subject ?? "Digestif, October 29",
      sections: options.sections ?? [{ title: "Came in", lines: ["Roman (Ada): shipped the D1 fold."] }],
      inbox,
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
