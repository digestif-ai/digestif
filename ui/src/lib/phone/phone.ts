// The phone web app's one read and its writes: what the relay holds for this phone, and a decision
// or an answer signed on the phone's own chain (docs/protocol.md, The phone, Items, Picks, Answers).
import { keyRawX25519, pickBody, seal, signEnvelope } from '#lib/mail.ts';
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
 * The decision body for one answer: a pick on a choice names it under `item`, sealed to the member and, on another member's choice, its author; an Acknowledge on a
 * notice is sealed to the member alone.
 */
export async function answerBody(e: Enrollment, item: PhoneItem, option: string): Promise<object | string> {
  if (item.kind === 'notice' || item.author === e.identity) return pickBody([e.encryptionPublic], item.hash, option);
  if (item.authorCard === undefined) return 'The member who wrote this choice has no card to seal a pick to.';
  return pickBody([e.encryptionPublic, keyRawX25519(item.authorCard)], item.hash, option);
}

/** Why the phone does not answer a circle question: its answer is plaintext, and the deny layer is the machine's. */
export const CIRCLE_ANSWER_ON_MACHINE = 'Answer a circle question on your machine, which checks it against your deny list first.';

/**
 * The item_answer body for the member's words on a question addressed to them by name: the
 * question's own `to` and the words sealed to every reader of it, each by the card key from their
 * newest card and the member by their own. A circle question's answer is signed plaintext through
 * the deny layer (docs/protocol.md, Items, Answers), which the phone does not hold, so the phone
 * refuses one. ISS-52907
 */
export async function itemAnswerBody(e: Enrollment, item: PhoneItem, text: string): Promise<object | string> {
  const words = text.trim();
  if (item.kind !== 'question') return 'Only a question takes an answer.';
  if (item.to === 'circle') return CIRCLE_ANSWER_ON_MACHINE;
  if (words === '') return 'Write an answer first.';
  const keys: Uint8Array<ArrayBuffer>[] = [];
  for (const r of item.readers) {
    if (r.identity === e.identity) keys.push(e.encryptionPublic);
    else if (r.card === undefined) return (r.name ?? 'A member it is addressed to') + ' has no card to seal an answer to.';
    else keys.push(keyRawX25519(r.card));
  }
  return { item: item.hash, to: item.to, sealed: await seal(keys, { text: words, voice: 'person' }) };
}

/** Sign [body] as the next envelope on the phone's own chain and append it to the relay. */
async function write(p: Extract<Phone, { stage: 'paired' }>, kind: string, body: object | string): Promise<string | undefined> {
  if (typeof body === 'string') return body;
  const c = await circle(p.keys);
  if (!c.ok) return c.message;
  const { seq, prev } = chainEnd(p.keys, p.envelopes);
  const { signed } = await signEnvelope(p.keys.signing, p.keys.ed25519, { seq, prev, epoch: c.data.epoch, kind }, body);
  const r = await append(p.keys, signed);
  return r.ok ? undefined : r.message;
}

/** Write the member's pick on one choice, or their Acknowledge on one notice, from this phone. */
export async function decide(p: Extract<Phone, { stage: 'paired' }>, item: PhoneItem, option: string): Promise<string | undefined> {
  return write(p, 'decision', await answerBody(p.enrollment, item, option));
}

/** Write the member's answer to one question from this phone. */
export async function answer(p: Extract<Phone, { stage: 'paired' }>, item: PhoneItem, text: string): Promise<string | undefined> {
  return write(p, 'item_answer', await itemAnswerBody(p.enrollment, item, text));
}
