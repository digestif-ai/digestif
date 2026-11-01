import { b64url, sha256, unb64url } from '#lib/mail.ts';

/**
 * The pairing code the phone web app shows (docs/protocol.md, The phone):
 * `p1.<base64url of 64 key bytes>.<base64url of the first 3 bytes of their sha256>`. This mirrors the
 * node's own parse (node/mail/phone.ml, parse_pairing_code) and its sentences, so the page can say a
 * code is mistyped while it is typed; the node still decides when the form is sent.
 */
export const NOT_A_CODE = 'Not a pairing code: it starts with p1. and comes from the phone.';
export const CHECK_MISMATCH = "The pairing code's check does not match; retype it.";

export type CodeCheck = { state: 'empty' } | { state: 'ok' } | { state: 'mistyped'; message: string };

const B64URL = /^[A-Za-z0-9_-]+$/;

/** The spaces a paste picked up are ignored, as the node ignores them. */
export async function checkPairingCode(input: string): Promise<CodeCheck> {
  const code = input.trim().replaceAll(' ', '');
  if (code === '') return { state: 'empty' };
  const parts = code.split('.');
  const [prefix, keys, check] = parts;
  if (parts.length !== 3 || prefix !== 'p1' || keys === undefined || check === undefined || !B64URL.test(keys))
    return { state: 'mistyped', message: NOT_A_CODE };
  let raw: Uint8Array<ArrayBuffer>;
  try {
    raw = unb64url(keys);
  } catch {
    return { state: 'mistyped', message: NOT_A_CODE };
  }
  if (raw.length !== 64) return { state: 'mistyped', message: NOT_A_CODE };
  const expected = b64url((await sha256(raw)).slice(0, 3));
  return expected === check ? { state: 'ok' } : { state: 'mistyped', message: CHECK_MISMATCH };
}
