// The relay, as the phone reads and writes it: every request signed by the phone's own key
// (docs/protocol.md, Request signing). The mailing relay serves this app, so the relay is the page's
// own origin.
import { signRequest, type Json, type SignedEnvelope } from '#lib/mail.ts';
import type { PhoneKeys } from './keystore.ts';

export interface Stored {
  relay_id: number;
  hash: string;
  envelope: SignedEnvelope['envelope'];
  body?: Json;
}

export type RelayResult<T> = { ok: true; data: T } | { ok: false; status: number; message: string };

async function call<T>(keys: PhoneKeys, method: string, path: string, body?: unknown): Promise<RelayResult<T>> {
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

/** Every envelope the relay serves this phone, oldest first. 401 until the relay admits its key. */
export async function envelopes(keys: PhoneKeys): Promise<RelayResult<Stored[]>> {
  const all: Stored[] = [];
  let after = 0;
  for (;;) {
    const page = await call<{ envelopes: Stored[]; next?: number }>(keys, 'GET', '/v0/envelopes?after=' + String(after) + '&limit=500');
    if (!page.ok) return page;
    all.push(...page.data.envelopes);
    const last = page.data.envelopes.at(-1)?.relay_id;
    if (page.data.next === undefined || last === undefined) return { ok: true, data: all };
    after = Math.max(page.data.next, last);
  }
}

export const circle = (keys: PhoneKeys): Promise<RelayResult<{ epoch: number }>> => call(keys, 'GET', '/v0/circle');

export const append = (keys: PhoneKeys, signed: SignedEnvelope): Promise<RelayResult<{ hash: string; relay_id: number }>> =>
  call(keys, 'POST', '/v0/envelopes', signed);
