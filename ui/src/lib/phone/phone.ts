// The phone web app's one read and one write: what the relay holds for this phone, and a pick
// signed on the phone's own chain (docs/protocol.md, The phone, Picks).
import { signEnvelope } from '#lib/mail.ts';
import { chainEnd, choices, findEnrollment, pausedSince, pickBody, type Choice } from './circle.ts';
import { enrollment, phoneKeys, saveEnrollment, type Enrollment, type PhoneKeys } from './keystore.ts';
import { append, circle, envelopes, type Stored } from './relay.ts';

export type Phone =
  | { stage: 'pairing'; keys: PhoneKeys }
  | { stage: 'paired'; keys: PhoneKeys; enrollment: Enrollment; envelopes: Stored[]; choices: Choice[]; pausedSince?: string }
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
    choices: await choices(e, r.data),
    ...(since === undefined ? {} : { pausedSince: since })
  };
}

/** Write the member's pick on one of the node's choices from this phone. */
export async function decide(p: Extract<Phone, { stage: 'paired' }>, item: string, option: string): Promise<string | undefined> {
  const c = await circle(p.keys);
  if (!c.ok) return c.message;
  const { seq, prev } = chainEnd(p.keys, p.envelopes);
  const body = await pickBody(p.enrollment.encryptionPublic, item, option);
  const { signed } = await signEnvelope(p.keys.signing, p.keys.ed25519, { seq, prev, epoch: c.data.epoch, kind: 'decision' }, body);
  const r = await append(p.keys, signed);
  return r.ok ? undefined : r.message;
}
