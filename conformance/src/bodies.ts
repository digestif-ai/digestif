// Circle-state bodies, docs/protocol.md "Circle-state bodies". Content bodies are not fixed by
// protocol v0 yet; the shapes below are what the suite sends and a relay need not read them.
import { isoTime, jcs, type Json } from "./encoding.ts";
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
 * `afterSeq` maps each device key the revoke stops to the last seq of its honest chain. A node reads
 * nothing above it, whatever the envelope's created_at says.
 */
export function revokeBody(by: Signer, target: string, afterSeq: Record<string, number>): Json {
  return { target, by: by.key, after_seq: afterSeq, signature: by.sign(jcs({ target, by: by.key, after_seq: afterSeq })) };
}

export function summaryBody(text: string, padding = ""): Json {
  return padding === "" ? { text } : { text, padding };
}

export function retractBody(target: string): Json {
  return { target };
}

export function answerBody(option: string): Json {
  return { sealed: Buffer.from(`conformance answer ${option}`).toString("base64url") };
}
