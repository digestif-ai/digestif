// The phone web app's one read and one write: what the relay holds for this phone, and a decision
// signed on the phone's own chain (docs/protocol.md, The phone, Items, Picks).
import { decisionBody, keyRawX25519, pickBody, signEnvelope } from '#lib/mail.ts';
import { chainEnd, findEnrollment, items, pausedSince, type PhoneItem } from './circle.ts';
import { enrollment, phoneKeys, saveEnrollment, type Enrollment, type PhoneKeys } from './keystore.ts';
import { append, circle, envelopes, type Stored } from './relay.ts';

export type Phone =
  | { stage: 'pairing'; keys: PhoneKeys }
  | { stage: 'paired'; keys: PhoneKeys; enrollment: Enrollment; envelopes: Stored[]; items: PhoneItem[]; pausedSince?: string }
  | { stage: 'error'; keys: PhoneKeys; message: string };

/** Until the laptop appends the phone's device body the relay answers 401, which means "pairing". */
export async function read(): Promise<Phone> {
  const keys = await phoneKeys();
  const r = await envelopes(keys);
  const held = await enrollment();
  if (!r.ok) {
    if (r.status === 401 && held === undefined) return { stage: 'pairing', keys };
    return { stage: 'error', keys, message: r.message };
  }
  let e = held;
  if (e === undefined) {
    e = await findEnrollment(keys, r.data);
    if (e === undefined) return { stage: 'pairing', keys };
    await saveEnrollment(e);
  }
  const since = await pausedSince(e, r.data);
  return {
    stage: 'paired',
    keys,
    enrollment: e,
    envelopes: r.data,
    items: await items(e, r.data),
    ...(since === undefined ? {} : { pausedSince: since })
  };
}

/**
 * The decision body for one answer: a replaced ask's names it under `ask`; a pick on a choice names it
 * under `item`, sealed to the member and, on another member's choice, its author; an Acknowledge on a
 * notice is sealed to the member alone.
 */
export async function answerBody(e: Enrollment, item: PhoneItem, option: string): Promise<object | string> {
  if (item.via === 'ask') return decisionBody(e.encryptionPublic, item.hash, option);
  if (item.kind === 'notice' || item.author === e.identity) return pickBody([e.encryptionPublic], item.hash, option);
  if (item.authorCard === undefined) return 'The member who wrote this choice has no card to seal a pick to.';
  return pickBody([e.encryptionPublic, keyRawX25519(item.authorCard)], item.hash, option);
}

/** Write the member's pick on one choice, or their Acknowledge on one notice, from this phone. */
export async function decide(p: Extract<Phone, { stage: 'paired' }>, item: PhoneItem, option: string): Promise<string | undefined> {
  const body = await answerBody(p.enrollment, item, option);
  if (typeof body === 'string') return body;
  const c = await circle(p.keys);
  if (!c.ok) return c.message;
  const { seq, prev } = chainEnd(p.keys, p.envelopes);
  const { signed } = await signEnvelope(p.keys.signing, p.keys.ed25519, { seq, prev, epoch: c.data.epoch, kind: 'decision' }, body);
  const r = await append(p.keys, signed);
  return r.ok ? undefined : r.message;
}
