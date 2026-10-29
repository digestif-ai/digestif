// The phone web app's one read and one write: what the relay holds for this phone, and a decision
// signed on the phone's own chain (docs/protocol.md, The phone, Asks and decisions).
import { decisionBody, signEnvelope } from '#lib/mail.ts';
import { asks, chainEnd, findEnrollment, type Ask } from './circle.ts';
import { enrollment, phoneKeys, saveEnrollment, type Enrollment, type PhoneKeys } from './keystore.ts';
import { append, circle, envelopes, type Stored } from './relay.ts';

export type Phone =
  | { stage: 'pairing'; keys: PhoneKeys }
  | { stage: 'paired'; keys: PhoneKeys; enrollment: Enrollment; envelopes: Stored[]; asks: Ask[] }
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
  return { stage: 'paired', keys, enrollment: e, envelopes: r.data, asks: await asks(e, r.data) };
}

/** Write the member's answer to one ask from this phone. */
export async function decide(p: Extract<Phone, { stage: 'paired' }>, ask: string, option: string): Promise<string | undefined> {
  const c = await circle(p.keys);
  if (!c.ok) return c.message;
  const { seq, prev } = chainEnd(p.keys, p.envelopes);
  const body = await decisionBody(p.enrollment.encryptionPublic, ask, option);
  const { signed } = await signEnvelope(p.keys.signing, p.keys.ed25519, { seq, prev, epoch: c.data.epoch, kind: 'decision' }, body);
  const r = await append(p.keys, signed);
  return r.ok ? undefined : r.message;
}
