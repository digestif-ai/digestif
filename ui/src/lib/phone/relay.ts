// The relay, as the phone reads and writes it: every request signed by the phone's own key
// (docs/protocol.md, Request signing). The mailing relay serves this app, so the relay is the page's
// own origin, and the phone's circle is that relay's home circle, read and written at its address
// (docs/protocol.md, Hosted circles).
import { signRequest, type Json, type SignedEnvelope } from '#lib/mail.ts';
import type { PhoneKeys } from './keystore.ts';

export interface Stored {
  relay_id: number;
  hash: string;
  envelope: SignedEnvelope['envelope'];
  body?: Json;
}

export type RelayResult<T> = { ok: true; data: T } | { ok: false; status: number; message: string };

/** The home circle's address on this relay, once read: it never changes while the page lives. */
let address: string | undefined;

/**
 * The path of the home circle's address on the relay serving this page, `/c/<root hex>`, read from
 * the relay's own unsigned GET /v0/relay. Every circle route lives under it; the unprefixed routes
 * are dropped (DIG-350).
 */
export async function circleAddress(get: typeof fetch = fetch): Promise<RelayResult<string>> {
  if (address !== undefined) return { ok: true, data: address };
  let response: Response;
  try {
    response = await get('/v0/relay');
  } catch {
    return { ok: false, status: 0, message: 'The relay did not answer.' };
  }
  if (!response.ok) return { ok: false, status: response.status, message: response.statusText || 'The relay refused the request.' };
  let home: unknown;
  try {
    home = ((await response.json()) as { home?: unknown }).home;
  } catch {
    return { ok: false, status: response.status, message: 'The relay answered GET /v0/relay with something other than JSON.' };
  }
  if (typeof home !== 'string' || !/^sha256:[0-9a-f]{64}$/.test(home))
    return { ok: false, status: 404, message: 'This relay hosts no home circle for the phone to read.' };
  address = '/c/' + home.slice('sha256:'.length);
  return { ok: true, data: address };
}

/** Forgets the address read, as a fresh page starts: for the tests. */
export function forgetCircleAddress(): void {
  address = undefined;
}

async function call<T>(keys: PhoneKeys, method: string, route: string, body?: unknown): Promise<RelayResult<T>> {
  const at = await circleAddress();
  if (!at.ok) return at;
  const path = at.data + route;
  const raw = body === undefined ? '' : JSON.stringify(body);
  const headers = await signRequest(keys.signing, keys.ed25519, { method, path, body: raw });
  let response: Response;
  try {
    response = await fetch(path, {
      method,
      headers: { ...headers, ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
      ...(body === undefined ? {} : { body: raw })
    });
  } catch {
    return { ok: false, status: 0, message: 'The relay did not answer.' };
  }
  if (!response.ok) {
    let message = response.statusText || 'The relay refused the request.';
    try {
      const errs = (await response.json()) as { code?: string; message?: string } | { code?: string; message?: string }[];
      const first = Array.isArray(errs) ? errs[0] : errs;
      if (first?.message !== undefined && first.message !== '') message = first.message;
      else if (first?.code !== undefined) message = first.code;
    } catch {
      // keep the status line
    }
    return { ok: false, status: response.status, message };
  }
  return { ok: true, data: (await response.json()) as T };
}

/**
 * Every envelope the relay serves this phone after relay position [after], oldest first, and the
 * position to read after next time. 401 until the relay admits its key.
 */
export async function envelopes(keys: PhoneKeys, after = 0): Promise<RelayResult<{ envelopes: Stored[]; after: number }>> {
  const all: Stored[] = [];
  let cursor = after;
  for (;;) {
    const page = await call<{ envelopes: Stored[]; next?: number }>(keys, 'GET', '/v0/envelopes?after=' + String(cursor) + '&limit=500');
    if (!page.ok) return page;
    all.push(...page.data.envelopes);
    const last = page.data.envelopes.at(-1)?.relay_id;
    if (last !== undefined) cursor = Math.max(cursor, last);
    if (page.data.next === undefined || last === undefined) return { ok: true, data: { envelopes: all, after: cursor } };
    cursor = Math.max(page.data.next, cursor);
  }
}

export const circle = (keys: PhoneKeys): Promise<RelayResult<{ epoch: number }>> => call(keys, 'GET', '/v0/circle');

export const append = (keys: PhoneKeys, signed: SignedEnvelope): Promise<RelayResult<{ hash: string; relay_id: number }>> =>
  call(keys, 'POST', '/v0/envelopes', signed);
