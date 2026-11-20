// The relay's log as this phone holds it (docs/protocol.md, The phone): every envelope the relay
// served it, in relay order, each checked once when it arrived and kept in IndexedDB with that
// verdict, so a load asks the relay only for what is past the position it last read and verifies
// only that. The relay's log only grows; the one change to an envelope already served is a retract
// dropping its target's body, which the phone applies to the copy it holds as the relay did.
import type { Json } from '#lib/mail.ts';
import { verifies } from './circle.ts';
import { heldLog, saveLog, type PhoneKeys } from './keystore.ts';
import { envelopes, type RelayResult, type Stored } from './relay.ts';

/** One envelope the phone holds, and whether its body verified when it arrived. */
export interface Held {
  stored: Stored;
  verified: boolean;
}

const target = (body: Json | undefined): string | undefined => {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) return undefined;
  const t = body['target'];
  return typeof t === 'string' ? t : undefined;
};

/**
 * [held] extended by [fresh], the envelopes the relay served past it: the whole log, and the
 * entries to write back, each new envelope and each held one a verified retract in [fresh] emptied.
 * An envelope already held is not taken twice.
 */
export async function extend(held: Held[], fresh: Stored[]): Promise<{ log: Held[]; changed: Held[] }> {
  const log = [...held];
  const at = new Map(log.map((h, i) => [h.stored.hash, i]));
  const changed: Held[] = [];
  for (const s of fresh) {
    if (at.has(s.hash)) continue;
    const h: Held = { stored: s, verified: await verifies(s) };
    at.set(s.hash, log.length);
    log.push(h);
    changed.push(h);
    if (!h.verified || s.envelope.kind !== 'retract') continue;
    const i = at.get(target(s.body) ?? '');
    const t = i === undefined ? undefined : log[i];
    if (i === undefined || t === undefined || t.stored.body === undefined) continue;
    const { body: _dropped, ...tombstone } = t.stored;
    const emptied: Held = { stored: tombstone, verified: false };
    log[i] = emptied;
    changed.push(emptied);
  }
  return { log, changed };
}

/**
 * The log the relay serves this phone, read from the relay past the position the phone holds and
 * kept for the next load. The relay's answer when it refuses (401 until it admits the phone's key).
 * A log the phone cannot keep is still returned: the next load reads it again.
 */
export async function sync(keys: PhoneKeys): Promise<RelayResult<Held[]>> {
  const held = await heldLog();
  const r = await envelopes(keys, held.after);
  if (!r.ok) return r;
  if (r.data.envelopes.length === 0) return { ok: true, data: held.log };
  const { log, changed } = await extend(held.log, r.data.envelopes);
  try {
    await saveLog(changed, r.data.after);
  } catch {
    // quota or a closed database: the log read stands for this load
  }
  return { ok: true, data: log };
}
