// Types for mail.mjs, for the TypeScript that imports it (the phone web app, the relay Worker).

export type Json =
  null | boolean | number | string | Json[] | { [key: string]: Json };

export interface Sealed {
  alg: string;
  recipients: { key: string; ephemeral: string; wrapped: string }[];
  nonce: string;
  ciphertext: string;
}

export interface Envelope {
  version: number;
  author: string;
  seq: number;
  prev?: string;
  created_at: string;
  epoch: number;
  kind: string;
  body_hash: string;
  signature: string;
}

export interface SignedEnvelope {
  envelope: Envelope;
  body?: unknown;
}

export interface PhoneKeys {
  signing: CryptoKeyPair;
  sealing: CryptoKeyPair;
  ed25519: Uint8Array<ArrayBuffer>;
  x25519: Uint8Array<ArrayBuffer>;
  code: string;
}

export const ALG: string;
export const ENVELOPE_VERSION: number;
export function b64url(bytes: Uint8Array<ArrayBuffer>): string;
export function unb64url(text: string): Uint8Array<ArrayBuffer>;
export function jcs(value: unknown): string;
export function sha256(
  bytes: Uint8Array<ArrayBuffer>,
): Promise<Uint8Array<ArrayBuffer>>;
export function hashText(bytes: Uint8Array<ArrayBuffer>): Promise<string>;
export function keyTextEd25519(raw: Uint8Array<ArrayBuffer>): string;
export function keyRawEd25519(text: string): Uint8Array<ArrayBuffer>;
export function keyTextX25519(raw: Uint8Array<ArrayBuffer>): string;
export function keyRawX25519(text: string): Uint8Array<ArrayBuffer>;
export function importX25519Private(
  privateRaw: Uint8Array<ArrayBuffer>,
  publicRaw: Uint8Array<ArrayBuffer>,
): Promise<CryptoKey>;
export function importEd25519Private(
  seedRaw: Uint8Array<ArrayBuffer>,
  extractable?: boolean,
): Promise<CryptoKey>;
export function importEncryptionKey(
  privateRaw: Uint8Array<ArrayBuffer>,
): Promise<{ privateKey: CryptoKey; publicRaw: Uint8Array<ArrayBuffer> }>;
export function seal(
  recipients: Uint8Array<ArrayBuffer>[],
  plaintext: unknown,
): Promise<Sealed>;
export function openSealed(
  privateKey: CryptoKey,
  publicRaw: Uint8Array<ArrayBuffer>,
  sealed: Sealed,
): Promise<Json>;
export function openLink(
  idText: string,
  secretText: string,
  sealedAnswerText: string,
): Promise<{ ask_title: string; label: string; signed: SignedEnvelope }>;
export function linkUrl(
  relay: string,
  idText: string,
  secretText: string,
): string;
export function verifyEnvelope(signed: SignedEnvelope): Promise<string>;
export function checkAnswer(
  payload: { signed: SignedEnvelope },
  opts: { mailKeys: string[]; ask: string },
): Promise<SignedEnvelope>;
export function pairingCode(
  ed25519Raw: Uint8Array<ArrayBuffer>,
  x25519Raw: Uint8Array<ArrayBuffer>,
): Promise<string>;
export function generatePhoneKeys(): Promise<PhoneKeys>;
export function openEnrollment(
  sealingPrivateKey: CryptoKey,
  sealingPublicRaw: Uint8Array<ArrayBuffer>,
  deviceBody: { enrollment: Sealed },
): Promise<{
  encryptionKey: Uint8Array<ArrayBuffer>;
  identityKey: string;
  relays: string[];
}>;
export function requestSignedString(r: {
  method: string;
  path: string;
  timestamp: string;
  nonce: string;
  body?: string;
}): Promise<string>;
export function signRequest(
  signingKey: CryptoKey,
  keyRaw: Uint8Array<ArrayBuffer>,
  r: {
    method: string;
    path: string;
    body?: string;
    timestamp?: string;
    nonce?: string;
  },
): Promise<Record<string, string>>;
export function signEnvelope(
  signingKey: CryptoKey,
  authorRaw: Uint8Array<ArrayBuffer>,
  fields: {
    seq: number;
    prev?: string | undefined;
    created_at?: string;
    epoch: number;
    kind: string;
  },
  body: unknown,
): Promise<{ signed: SignedEnvelope; hash: string }>;
export function verifyDevice(body: {
  identity_key: string;
  key: string;
  role: string;
  signature: string;
}): Promise<boolean>;
export function decisionBody(
  memberPublicRaw: Uint8Array<ArrayBuffer>,
  ask: string,
  option: string,
): Promise<{ ask: string; sealed: Sealed }>;
