// Circle-state bodies, docs/protocol.md "Circle-state bodies". Content bodies are not fixed by
// protocol v0 yet; the shapes below are what the suite sends and a relay need not read them.
import { b64url, bytesOf, isoTime, jcs, type Json } from "./encoding.ts";
import { Signer } from "./keys.ts";

export interface Guest {
  name: string;
  invite_key: string;
  expires_at: string;
}

export const INVITE_TTL_MS = 72 * 3600 * 1000;

export function dinnerBody(host: Signer, label: string, guests: Guest[], relays: string[], date = new Date()): Json {
  return {
    host: host.key,
    dinner: { date: isoTime(date).slice(0, 10), label },
    guests: guests.map((g) => ({ name: g.name, invite_key: g.invite_key, expires_at: g.expires_at })),
    relays,
  };
}

export function joinBody(dinnerHash: string, invite: Signer, identity: Signer, device: Signer): Json {
  return {
    dinner: dinnerHash,
    identity_key: identity.key,
    identity_signature: invite.sign(jcs({ dinner: dinnerHash, identity_key: identity.key })),
    device_key: device.key,
    device_signature: identity.sign(jcs({ identity_key: identity.key, device_key: device.key, role: "device" })),
  };
}

export function deviceBody(identity: Signer, key: string, role: "device" | "mail"): Json {
  return {
    identity_key: identity.key,
    key,
    role,
    signature: identity.sign(jcs({ identity_key: identity.key, key, role })),
  };
}

/**
 * `afterSeq` maps each device key the revoke stops to the last seq of its honest chain, and
 * `mailRead` each mail key it stops to the hashes of that key's envelopes the revoker holds. A node
 * reads nothing outside them, whatever the envelope's created_at says.
 */
export function revokeBody(by: Signer, target: string, afterSeq: Record<string, number>, mailRead: Record<string, string[]> = {}): Json {
  const signed = { target, by: by.key, after_seq: afterSeq, mail_read: mailRead };
  return { ...signed, signature: by.sign(jcs(signed)) };
}

export function summaryBody(text: string, padding = ""): Json {
  return padding === "" ? { text } : { text, padding };
}

export function retractBody(target: string): Json {
  return { target };
}

export function answerBody(option: string): Json {
  return { sealed: b64url(bytesOf(`conformance answer ${option}`)) };
}

/**
 * A release-key revocation carried on the circle (docs/protocol.md, release_revocation): the
 * document's exact bytes as base64url and one signature over `DIGESTIF-REVOCATION-V0\n<bytes>`. A
 * relay checks only the two fields' shapes; the suite's release key is a throwaway, which is the
 * point: a relay serves it whoever signed it.
 */
export function releaseRevocationBody(releaseKey: Signer, document: string): Json {
  const bytes = bytesOf(document);
  const signed = new Uint8Array([...bytesOf("DIGESTIF-REVOCATION-V0\n"), ...bytes]);
  return { document: b64url(bytes), signatures: [{ key: releaseKey.key, signature: releaseKey.sign(signed) }] };
}
