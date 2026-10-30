// The envelope and its three derived values, docs/protocol.md "The envelope".
import { hashOf, isoTime, jcs, type Json } from "./encoding.ts";
import { Signer, verifySignature } from "./keys.ts";

/** docs/protocol.md "The envelope": the version every envelope carries, and the only one a relay or node reads. */
export const ENVELOPE_VERSION = 2;

export const CIRCLE_STATE_KINDS = ["dinner", "join", "device", "revoke", "card", "relay"] as const;
export const CONTENT_KINDS = ["summary", "question", "answer", "proposal", "ask", "decision", "digest", "retract"] as const;
export type Kind = (typeof CIRCLE_STATE_KINDS)[number] | (typeof CONTENT_KINDS)[number];

export function isCircleState(kind: string): boolean {
  return (CIRCLE_STATE_KINDS as readonly string[]).includes(kind);
}

export function isKind(kind: unknown): kind is Kind {
  return (
    typeof kind === "string" &&
    ((CIRCLE_STATE_KINDS as readonly string[]).includes(kind) || (CONTENT_KINDS as readonly string[]).includes(kind))
  );
}

export interface Envelope {
  version: number;
  author: string;
  seq: number;
  prev?: string;
  created_at: string;
  epoch: number;
  kind: Kind;
  body_hash: string;
  signature: string;
}

export interface SignedEnvelope {
  envelope: Envelope;
  body?: Json;
}

export interface StoredEnvelope {
  relay_id: number;
  hash: string;
  envelope: Envelope;
  body?: Json;
  received_at: string;
}

export function unsignedPart(envelope: Envelope): Omit<Envelope, "signature"> {
  const { signature: _signature, ...rest } = envelope;
  return rest;
}

/** sha256(JCS(envelope with signature)): the id nodes dedupe by and prev names. */
export function envelopeHash(envelope: Envelope): string {
  return hashOf(envelope);
}

export function verifyEnvelope(envelope: Envelope): boolean {
  return verifySignature(envelope.author, jcs(unsignedPart(envelope)), envelope.signature);
}

export function bodyMatches(signed: SignedEnvelope): boolean {
  return signed.body !== undefined && hashOf(signed.body) === signed.envelope.body_hash;
}

export interface EnvelopeFields {
  kind: Kind;
  body: Json;
  seq: number;
  prev?: string;
  epoch: number;
  createdAt?: Date;
}

export function signEnvelope(signer: Signer, fields: EnvelopeFields): SignedEnvelope {
  const unsigned: Omit<Envelope, "signature"> = {
    version: ENVELOPE_VERSION,
    author: signer.key,
    seq: fields.seq,
    ...(fields.prev === undefined ? {} : { prev: fields.prev }),
    created_at: isoTime(fields.createdAt ?? new Date()),
    epoch: fields.epoch,
    kind: fields.kind,
    body_hash: hashOf(fields.body),
  };
  const envelope: Envelope = { ...unsigned, signature: signer.sign(jcs(unsigned)) };
  return { envelope, body: fields.body };
}

/** One chained author: tracks seq and prev so every envelope it signs extends its chain. */
export class Author {
  readonly signer: Signer;
  seq: number;
  prev: string | undefined;

  constructor(signer: Signer, seq = 0, prev?: string) {
    this.signer = signer;
    this.seq = seq;
    this.prev = prev;
  }

  get key(): string {
    return this.signer.key;
  }

  /** Signs the next envelope in this author's chain and advances the chain. */
  next(kind: Kind, body: Json, epoch: number, createdAt?: Date): SignedEnvelope {
    const signed = this.peek(kind, body, epoch, createdAt);
    this.seq = signed.envelope.seq;
    this.prev = envelopeHash(signed.envelope);
    return signed;
  }

  /** Signs what next() would, without advancing: the material for a fork. */
  peek(kind: Kind, body: Json, epoch: number, createdAt?: Date): SignedEnvelope {
    return signEnvelope(this.signer, {
      kind,
      body,
      seq: this.seq + 1,
      ...(this.prev === undefined ? {} : { prev: this.prev }),
      epoch,
      ...(createdAt === undefined ? {} : { createdAt }),
    });
  }
}
