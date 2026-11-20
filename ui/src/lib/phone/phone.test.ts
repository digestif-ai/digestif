// The phone's writes against a relay whose answers can be lost: the chain's end is read as the relay
// holds it, not from the page's snapshot, and an append whose response was lost counts as written.
// DIG-239
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type * as mail from '#lib/mail.ts';
import { generatePhoneKeys } from '#lib/mail.ts';
import type { PhoneKeys } from './keystore.ts';
import type { Stored } from './relay.ts';

const relay = vi.hoisted(() => ({
  held: [] as Stored[],
  /** The next append is stored but its response is lost. */
  loseNext: false
}));

vi.mock('./keystore.ts', () => ({}));
// The log as the phone reads it: the relay's, each envelope held as verified.
vi.mock('./log.ts', () => ({
  sync: () => Promise.resolve({ ok: true, data: relay.held.map((stored) => ({ stored, verified: true })) })
}));
vi.mock('./relay.ts', () => ({
  circle: () => Promise.resolve({ ok: true, data: { epoch: 1 } }),
  append: (_keys: PhoneKeys, signed: { envelope: Stored['envelope'] }) => {
    const mine = relay.held.filter((s) => s.envelope.author === signed.envelope.author);
    const end = mine.at(-1);
    if (signed.envelope.seq !== (end === undefined ? 1 : end.envelope.seq + 1))
      return Promise.resolve({ ok: false, status: 409, message: 'fork' });
    const hash = 'h' + String(relay.held.length + 1);
    relay.held.push({ relay_id: relay.held.length + 1, hash, envelope: signed.envelope });
    if (relay.loseNext) {
      relay.loseNext = false;
      return Promise.resolve({ ok: false, status: 0, message: 'The relay did not answer.' });
    }
    return Promise.resolve({ ok: true, data: { hash, relay_id: relay.held.length } });
  }
}));

vi.mock('#lib/mail.ts', async (actual) => {
  const real = await actual<typeof mail>();
  return {
    ...real,
    // The fake relay names a stored envelope by its position, so the hash a write looks for is that.
    signEnvelope: async (...args: Parameters<typeof real.signEnvelope>) => {
      const r = await real.signEnvelope(...args);
      return { ...r, hash: 'h' + String(relay.held.length + 1) };
    }
  };
});

const { decide } = await import('./phone.ts');

async function paired() {
  const k = await generatePhoneKeys();
  const keys: PhoneKeys = {
    signing: k.signing.privateKey,
    sealing: k.sealing.privateKey,
    ed25519: k.ed25519,
    x25519: k.x25519,
    code: k.code
  };
  const encryptionPublic = k.x25519;
  return {
    stage: 'paired' as const,
    keys,
    enrollment: { encryption: k.sealing.privateKey, encryptionPublic, identity: 'me', relays: [] },
    envelopes: [] as Stored[],
    items: []
  };
}

const notice = { kind: 'notice', hash: 'n1', author: 'me' } as unknown as Parameters<typeof decide>[1];

describe('phone writes', () => {
  beforeEach(() => {
    relay.held = [];
    relay.loseNext = false;
  });

  it('counts an append whose response was lost as written', async () => {
    const p = await paired();
    relay.loseNext = true;
    expect(await decide(p, notice, 'ack')).toBeUndefined();
    expect(relay.held).toHaveLength(1);
  });

  it('signs the seq after the relay end, not the snapshot end', async () => {
    const p = await paired();
    relay.loseNext = true;
    await decide(p, notice, 'ack');
    // The page never reloaded: its snapshot still holds no envelope of the phone's.
    expect(await decide(p, notice, 'ack')).toBeUndefined();
    expect(relay.held.map((s) => s.envelope.seq)).toEqual([1, 2]);
  });
});
