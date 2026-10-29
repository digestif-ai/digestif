// A local relay that implements spec/digestif-relay.json in memory, so the node and the suite can be
// exercised before a real relay is deployed. Two modes:
//   checked   (the default) enforces everything a relay must: the conformance relay cases pass on it.
//   unchecked accepts any envelope whose own signature verifies and serves it to anyone. It plays a
//             relay that is lagging, buggy or hostile, which is what the node cases need to prove the
//             node does not trust a relay's word.
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { isoTime, jcs, type Json } from "./encoding.ts";
import { verifySignature } from "./keys.ts";
import {
  bodyMatches,
  ENVELOPE_VERSION,
  envelopeHash,
  isCircleState,
  isKind,
  verifyEnvelope,
  type Envelope,
  type SignedEnvelope,
  type StoredEnvelope,
} from "./envelope.ts";
import { Fold, type FoldBreak, type FoldError } from "./fold.ts";
import { HEADER_KEY, HEADER_NONCE, HEADER_SIGNATURE, HEADER_TIMESTAMP, requestString } from "./request.ts";

export interface RelayLimits {
  max_envelope_bytes: number;
  max_appends_per_device_per_day: number;
  max_page_size: number;
  skew_seconds: number;
}

export const DEFAULT_LIMITS: RelayLimits = {
  max_envelope_bytes: 65536,
  max_appends_per_device_per_day: 500,
  max_page_size: 500,
  skew_seconds: 3600,
};

/** Rules the relay can be told to skip, so the self-test can prove each case catches its absence. */
export type RelayBreak =
  | FoldBreak
  | "duplicate"
  | "fork"
  | "sequence"
  | "mail-sequence"
  | "skew"
  | "nonce"
  | "epoch"
  | "retract-drop"
  | "size"
  | "rate"
  | "invite-signer";

export interface FakeRelayOptions {
  root: string;
  breaks?: RelayBreak[];
  mode?: "checked" | "unchecked";
  limits?: Partial<RelayLimits>;
  /** The relay's clock; tests pin it. */
  now?: () => Date;
}

type ErrorCode =
  | FoldError
  | "stale_request"
  | "replayed_nonce"
  | "sequence_regression"
  | "fork"
  | "too_large"
  | "rate_limited";

class Refusal {
  readonly status: number;
  readonly code: ErrorCode;
  readonly message: string;
  constructor(status: number, code: ErrorCode, message: string) {
    this.status = status;
    this.code = code;
    this.message = message;
  }
}

interface Authenticated {
  key: string | undefined;
}

export class FakeRelay {
  readonly root: string;
  readonly mode: "checked" | "unchecked";
  readonly limits: RelayLimits;
  private readonly breaks: ReadonlySet<RelayBreak>;
  private readonly now: () => Date;
  private readonly fold: Fold;
  private readonly stored: StoredEnvelope[] = [];
  private readonly byHash = new Map<string, StoredEnvelope>();
  /** author -> seq -> hash, for the sequence and fork rules. */
  private readonly chains = new Map<string, Map<number, string>>();
  private readonly lastSeq = new Map<string, number>();
  /** key -> nonce -> the time it stops mattering. */
  private readonly nonces = new Map<string, Map<string, number>>();
  /** key + UTC day -> appends accepted. */
  private readonly daily = new Map<string, number>();
  private server: Server | undefined;

  constructor(options: FakeRelayOptions) {
    this.root = options.root;
    this.mode = options.mode ?? "checked";
    this.limits = { ...DEFAULT_LIMITS, ...options.limits };
    this.now = options.now ?? (() => new Date());
    this.breaks = new Set(options.breaks ?? []);
    const foldBreaks: FoldBreak[] = ["expiry", "spent", "revocation", "retract-author", "cutoff-shape", "self-device", "device-signature"];
    this.fold = new Fold(options.root, { breaks: foldBreaks.filter((b) => this.breaks.has(b)) });
  }

  async listen(port = 0, host = "127.0.0.1"): Promise<string> {
    const server = createServer((req, res) => {
      this.handle(req, res).catch((error: unknown) => {
        respond(res, 500, { code: "malformed", message: String(error) });
      });
    });
    this.server = server;
    await new Promise<void>((resolve) => server.listen(port, host, resolve));
    const address = server.address() as AddressInfo;
    return `http://${host}:${address.port}`;
  }

  async close(): Promise<void> {
    const server = this.server;
    if (server === undefined) return;
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }

  private async handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const url = new URL(req.url ?? "/", "http://relay.local");
    const raw = await readBody(req);
    try {
      if (req.method === "POST" && url.pathname === "/v0/envelopes") {
        const [status, receipt] = this.append(req, url, raw);
        return respond(res, status, receipt);
      }
      if (req.method === "GET" && url.pathname === "/v0/envelopes") return respond(res, 200, this.page(req, url, raw));
      if (req.method === "GET" && url.pathname === "/v0/circle") return respond(res, 200, this.circle(req, url, raw));
      if (req.method === "GET" && url.pathname.startsWith("/v0/invites/")) {
        const found = this.invite(req, url, raw, decodeURIComponent(url.pathname.slice("/v0/invites/".length)));
        return found === undefined ? respond(res, 404, null) : respond(res, 200, found);
      }
      return respond(res, 404, { code: "malformed", message: `no route ${req.method} ${url.pathname}` });
    } catch (error) {
      if (!(error instanceof Refusal)) throw error;
      const payload = { code: error.code, message: error.message };
      return respond(res, error.status, error.status === 422 ? [payload] : payload);
    }
  }

  /** The bootstrap read: the dinner listing an open invite, to the invite key alone. */
  private invite(req: IncomingMessage, url: URL, raw: string, inviteKey: string): Json | undefined {
    if (this.mode === "checked") {
      const signer = header(req, HEADER_KEY);
      if (signer !== inviteKey && !this.breaks.has("invite-signer")) throw new Refusal(401, "not_admitted", "the bootstrap read is signed by the invite key it names");
      this.authenticate(req, url, raw, false, false);
      if (this.breaks.has("invite-signer")) return this.byHash.get(this.root) as unknown as Json;
    }
    const dinner = this.fold.openInvite(inviteKey, this.now());
    const stored = dinner === undefined ? undefined : this.byHash.get(dinner);
    return stored === undefined ? undefined : (stored as unknown as Json);
  }

  /** Request signing: the four headers, the skew window, the nonce, and an admitted signer. */
  private authenticate(req: IncomingMessage, url: URL, raw: string, allowUnsigned: boolean, admitted = true): Authenticated {
    const key = header(req, HEADER_KEY);
    if (key === undefined) {
      if (allowUnsigned || this.mode === "unchecked") return { key: undefined };
      throw new Refusal(401, "not_admitted", "Digestif-Key is required");
    }
    if (this.mode === "unchecked") return { key };
    const timestamp = header(req, HEADER_TIMESTAMP);
    const nonce = header(req, HEADER_NONCE);
    const signature = header(req, HEADER_SIGNATURE);
    if (timestamp === undefined || nonce === undefined || signature === undefined) {
      throw new Refusal(401, "bad_signature", "Digestif-Timestamp, Digestif-Nonce and Digestif-Signature are required");
    }
    const signed = requestString(req.method ?? "", url.pathname + url.search, timestamp, nonce, raw);
    if (!verifySignature(key, signed, signature)) throw new Refusal(401, "bad_signature", "the request signature does not verify");
    const claimed = Date.parse(timestamp);
    const now = this.now().getTime();
    const window = this.limits.skew_seconds * 1000;
    if ((Number.isNaN(claimed) || Math.abs(now - claimed) > window) && !this.breaks.has("skew")) {
      throw new Refusal(401, "stale_request", `timestamp ${timestamp} is outside ${this.limits.skew_seconds}s of the relay clock`);
    }
    const seen = this.nonces.get(key) ?? new Map<string, number>();
    for (const [old, until] of seen) if (until < now) seen.delete(old);
    if (seen.has(nonce) && !this.breaks.has("nonce")) throw new Refusal(401, "replayed_nonce", "this nonce was already used by this key");
    seen.set(nonce, claimed + window);
    this.nonces.set(key, seen);
    if (admitted && this.fold.activeAuthor(key) === undefined) throw new Refusal(401, "not_admitted", "the signing key is not admitted");
    return { key };
  }

  private append(req: IncomingMessage, url: URL, raw: string): [number, Json] {
    if (this.mode === "checked" && Buffer.byteLength(raw) > this.limits.max_envelope_bytes && !this.breaks.has("size")) {
      throw new Refusal(422, "too_large", `the append is ${Buffer.byteLength(raw)} bytes, over ${this.limits.max_envelope_bytes}`);
    }
    const signed = parseSigned(raw);
    const { envelope } = signed;
    const bootstrap = envelope.kind === "dinner" || envelope.kind === "join" || isSelfAuthoredDevice(signed);
    const auth = this.authenticate(req, url, raw, bootstrap);
    if (!verifyEnvelope(envelope)) throw new Refusal(422, "bad_signature", "the envelope signature does not verify");
    if (signed.body !== undefined && !bodyMatches(signed)) throw new Refusal(422, "bad_signature", "body_hash does not match the body");
    if (signed.body === undefined) throw new Refusal(422, "malformed", "an append carries its body");
    const hash = envelopeHash(envelope);
    const held = this.byHash.get(hash);
    if (held !== undefined && !this.breaks.has("duplicate")) return [200, { status: "duplicate", relay_id: held.relay_id, hash }];
    if (this.mode === "checked") this.check(auth, envelope, signed, hash);
    return [201, this.store(envelope, signed.body, hash)];
  }

  private check(auth: Authenticated, envelope: Envelope, signed: SignedEnvelope, hash: string): void {
    if (auth.key !== undefined && auth.key !== envelope.author) {
      throw new Refusal(401, "not_admitted", "the request signer is not the envelope author");
    }
    const author = this.fold.activeAuthor(envelope.author);
    if (envelope.kind !== "join") this.checkChain(envelope, hash, author?.role === "mail" && !this.breaks.has("mail-sequence"));
    const day = `${envelope.author}/${isoTime(this.now()).slice(0, 10)}`;
    if ((this.daily.get(day) ?? 0) >= this.limits.max_appends_per_device_per_day && !this.breaks.has("rate")) {
      throw new Refusal(429, "rate_limited", `this key has made ${this.limits.max_appends_per_device_per_day} appends today`);
    }
    const error = this.fold.apply({ hash, envelope, body: signed.body, position: this.stored.length + 1, now: this.now() });
    if (error !== null) throw new Refusal(422, error, `the fold refused this ${envelope.kind}`);
    this.daily.set(day, (this.daily.get(day) ?? 0) + 1);
  }

  /** The sequence and fork rules. A join is its invite key's only envelope, so the spent rule covers it. */
  private checkChain(envelope: Envelope, hash: string, mail: boolean): void {
    const chain = this.chains.get(envelope.author);
    const heldAtSeq = chain?.get(envelope.seq);
    if (heldAtSeq !== undefined && heldAtSeq !== hash && !this.breaks.has("fork")) {
      throw new Refusal(422, "fork", `a different envelope from this author at seq ${envelope.seq} is already held`);
    }
    if (!mail && !this.breaks.has("sequence")) {
      const last = this.lastSeq.get(envelope.author) ?? 0;
      if (envelope.seq <= last) {
        throw new Refusal(422, "sequence_regression", `seq ${envelope.seq} is not greater than ${last}, the last held`);
      }
    }
  }

  private store(envelope: Envelope, body: Json | undefined, hash: string): Json {
    const entry: StoredEnvelope = {
      relay_id: this.stored.length + 1,
      hash,
      envelope,
      ...(body === undefined ? {} : { body }),
      received_at: isoTime(this.now()),
    };
    this.stored.push(entry);
    this.byHash.set(hash, entry);
    const chain = this.chains.get(envelope.author) ?? new Map<number, string>();
    chain.set(envelope.seq, hash);
    this.chains.set(envelope.author, chain);
    this.lastSeq.set(envelope.author, Math.max(this.lastSeq.get(envelope.author) ?? 0, envelope.seq));
    if (this.mode === "checked" && !this.breaks.has("retract-drop") && envelope.kind === "retract" && typeof body === "object" && body !== null && !Array.isArray(body)) {
      const target = this.byHash.get(String(body["target"]));
      if (target !== undefined) delete target.body;
    }
    return { status: "accepted", relay_id: entry.relay_id, hash };
  }

  private readerEpoch(req: IncomingMessage, url: URL, raw: string): number | undefined {
    const auth = this.authenticate(req, url, raw, false);
    if (auth.key === undefined) return undefined;
    return this.fold.keys.get(auth.key)?.join_epoch;
  }

  private page(req: IncomingMessage, url: URL, raw: string): Json {
    const floor = this.readerEpoch(req, url, raw) ?? 0;
    const after = Number(url.searchParams.get("after") ?? "0");
    const limit = Math.min(Number(url.searchParams.get("limit") ?? this.limits.max_page_size), this.limits.max_page_size);
    const visible = this.stored.filter(
      (s) => s.relay_id > after && (this.mode === "unchecked" || this.breaks.has("epoch") || isCircleState(s.envelope.kind) || s.envelope.epoch >= floor),
    );
    const page = visible.slice(0, Math.max(1, limit));
    const last = page[page.length - 1];
    const more = visible.length > page.length && last !== undefined;
    return { envelopes: page as unknown as Json, ...(more ? { next: last.relay_id } : {}) };
  }

  private circle(req: IncomingMessage, url: URL, raw: string): Json {
    this.readerEpoch(req, url, raw);
    return {
      root: this.root,
      epoch: this.fold.epoch,
      keys: this.fold.admittedKeys() as unknown as Json,
      limits: this.limits as unknown as Json,
    };
  }
}

/** A device message authored by the key it admits: the lost-laptop bootstrap, proved by the identity signature inside it. */
function isSelfAuthoredDevice(signed: SignedEnvelope): boolean {
  const body = signed.body;
  return signed.envelope.kind === "device" && typeof body === "object" && body !== null && !Array.isArray(body) && body["key"] === signed.envelope.author;
}

function parseSigned(raw: string): SignedEnvelope {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new Refusal(422, "malformed", "the body is not JSON");
  }
  const signed = value as SignedEnvelope;
  const e = signed?.envelope as Envelope | undefined;
  const wellFormed =
    e !== undefined &&
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
  return signed;
}

function header(req: IncomingMessage, name: string): string | undefined {
  const value = req.headers[name];
  return Array.isArray(value) ? value[0] : value;
}

async function readBody(req: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks).toString("utf8");
}

function respond(res: ServerResponse, status: number, payload: unknown): void {
  const text = jcs(payload);
  res.writeHead(status, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(text) });
  res.end(text);
}
