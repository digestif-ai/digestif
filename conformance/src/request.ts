// Request signing, docs/protocol.md "Request signing", and an HTTP client for the relay surface in
// spec/digestif-relay.json. Every knob a conformance case needs to turn (the clock, the nonce, an
// unsigned bootstrap append) is an option, never a second code path.
import "./node-crypto.ts"; // installs the node:crypto SuiteCrypto: this module only runs on Node
import { randomBytes } from "node:crypto";
import { b64url, isoTime, jcs, sha256Hex } from "./encoding.ts";
import { Signer } from "./keys.ts";
import type { SignedEnvelope, StoredEnvelope } from "./envelope.ts";

export const HEADER_KEY = "digestif-key";
export const HEADER_TIMESTAMP = "digestif-timestamp";
export const HEADER_NONCE = "digestif-nonce";
export const HEADER_SIGNATURE = "digestif-signature";

export function requestString(method: string, pathWithQuery: string, timestamp: string, nonce: string, body: string): string {
  return ["DIGESTIF-REQUEST-V0", method, pathWithQuery, timestamp, nonce, sha256Hex(body)].join("\n");
}

export function newNonce(): string {
  return b64url(randomBytes(16));
}

export interface SignOptions {
  /** The clock the request claims; defaults to now. */
  timestamp?: Date;
  nonce?: string;
  /** Send none of the four Digestif headers: the bootstrap append. */
  unsigned?: boolean;
  /** Sign as someone other than the client's own key. */
  signer?: Signer;
}

export interface HttpResult {
  status: number;
  body: unknown;
  text: string;
  /** The exact request, so a case can replay it byte for byte. */
  request: { method: string; url: string; headers: Record<string, string>; body: string };
}

export function signedHeaders(signer: Signer, method: string, pathWithQuery: string, body: string, options: SignOptions = {}): Record<string, string> {
  const timestamp = isoTime(options.timestamp ?? new Date());
  const nonce = options.nonce ?? newNonce();
  return {
    "Digestif-Key": signer.key,
    "Digestif-Timestamp": timestamp,
    "Digestif-Nonce": nonce,
    "Digestif-Signature": signer.sign(requestString(method, pathWithQuery, timestamp, nonce, body)),
  };
}

export async function sendRaw(request: HttpResult["request"]): Promise<HttpResult> {
  const response = await fetch(request.url, {
    method: request.method,
    headers: request.headers,
    ...(request.method === "GET" ? {} : { body: request.body }),
  });
  const text = await response.text();
  let body: unknown = undefined;
  try {
    body = text === "" ? undefined : JSON.parse(text);
  } catch {
    body = undefined;
  }
  return { status: response.status, body, text, request };
}

export interface Page {
  envelopes: StoredEnvelope[];
  next?: number;
}

export class RelayClient {
  readonly baseUrl: string;
  readonly signer: Signer;

  constructor(baseUrl: string, signer: Signer) {
    this.baseUrl = baseUrl.replace(/\/+$/, "");
    this.signer = signer;
  }

  async send(method: string, path: string, body: string, options: SignOptions = {}): Promise<HttpResult> {
    const url = new URL(this.baseUrl + path);
    const headers: Record<string, string> = method === "GET" ? {} : { "Content-Type": "application/json" };
    if (!options.unsigned) {
      Object.assign(headers, signedHeaders(options.signer ?? this.signer, method, url.pathname + url.search, body, options));
    }
    return sendRaw({ method, url: url.toString(), headers, body });
  }

  append(signed: SignedEnvelope, options: SignOptions = {}): Promise<HttpResult> {
    return this.send("POST", "/v0/envelopes", jcs(signed), options);
  }

  /** Appends a body the caller has already encoded, for size cases that must control the bytes. */
  appendRaw(body: string, options: SignOptions = {}): Promise<HttpResult> {
    return this.send("POST", "/v0/envelopes", body, options);
  }

  /** The bootstrap read, signed by the client's key (the invite key) unless options name another. */
  invite(inviteKey: string, options: SignOptions = {}): Promise<HttpResult> {
    return this.send("GET", `/v0/invites/${inviteKey}`, "", options);
  }

  circle(options: SignOptions = {}): Promise<HttpResult> {
    return this.send("GET", "/v0/circle", "", options);
  }

  page(after: number, limit?: number, options: SignOptions = {}): Promise<HttpResult> {
    const query = limit === undefined ? `after=${after}` : `after=${after}&limit=${limit}`;
    return this.send("GET", `/v0/envelopes?${query}`, "", options);
  }

  /** Every envelope this reader may see, following next to the end. */
  async fetchAll(options: SignOptions = {}): Promise<StoredEnvelope[]> {
    const all: StoredEnvelope[] = [];
    let after = 0;
    for (;;) {
      const result = await this.page(after, undefined, options);
      if (result.status !== 200) {
        throw new Error(`GET /v0/envelopes?after=${after} answered ${result.status}: ${result.text}`);
      }
      const page = result.body as Page;
      all.push(...page.envelopes);
      if (page.next === undefined || page.next === null) return all;
      if (page.next <= after) throw new Error(`GET /v0/envelopes returned next=${page.next}, not after ${after}`);
      after = page.next;
    }
  }
}
