import { describe, expect, it } from 'vitest';
import { importEncryptionKey, keyTextEd25519, openSealed, seal, signEnvelope, unb64url, type Json } from '#lib/mail.ts';
import { choices, pickBody } from './circle.ts';
import type { Enrollment } from './keystore.ts';
import type { Stored } from './relay.ts';

const subtle = globalThis.crypto.subtle;
const rawOf = async (k: CryptoKey): Promise<Uint8Array<ArrayBuffer>> => new Uint8Array(await subtle.exportKey('raw', k));

/** A member whose laptop founded the circle, the envelopes it wrote, and the phone's enrollment. */
async function member() {
  const identity = (await subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify'])) as CryptoKeyPair;
  const laptop = (await subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify'])) as CryptoKeyPair;
  const x = (await subtle.generateKey({ name: 'X25519' }, true, ['deriveBits'])) as CryptoKeyPair;
  const k = await importEncryptionKey(unb64url((await subtle.exportKey('jwk', x.privateKey)).d ?? ''));
  const identityText = keyTextEd25519(await rawOf(identity.publicKey));
  const laptopRaw = await rawOf(laptop.publicKey);
  const enrollment: Enrollment = { encryption: k.privateKey, encryptionPublic: k.publicRaw, identity: identityText, relays: [] };
  const stored: Stored[] = [];
  let prev: string | undefined;
  const writes = async (kind: string, body: Json, created_at: string): Promise<string> => {
    const { signed, hash } = await signEnvelope(
      laptop.privateKey,
      laptopRaw,
      { seq: stored.length + 1, prev, epoch: 1, kind, created_at },
      body
    );
    prev = hash;
    stored.push({ relay_id: stored.length + 1, hash, envelope: signed.envelope, body: signed.body as Json });
    return hash;
  };
  await writes(
    'dinner',
    { host: identityText, dinner: { date: '2026-10-27', label: 'AI Dinner 2' }, guests: [], relays: [] },
    '2026-11-01T00:00:00.000Z'
  );
  return { enrollment, stored, writes, identityText };
}

const pausedItem = {
  kind: 'choice',
  subject: 'paused',
  voice: 'node',
  title: 'Digestif paused. Unpause?',
  detail: '',
  options: [
    { id: 'unpause', label: 'Unpause', recommended: true },
    { id: 'stay_paused', label: 'Stay paused' }
  ],
  default: 'stay_paused'
};

describe("the phone's choices (docs/protocol.md, Items, Picks)", () => {
  it("reads the node's own choices addressed to the member alone, with the first pick on each", async () => {
    const m = await member();
    const sealed = async (item: Json): Promise<Json> => (await seal([m.enrollment.encryptionPublic], item)) as unknown as Json;
    const paused = await m.writes('item', { to: [m.identityText], sealed: await sealed(pausedItem) }, '2026-11-02T00:00:00.000Z');
    const join = await m.writes(
      'item',
      {
        to: [m.identityText],
        sealed: await sealed({ ...pausedItem, subject: 'join', title: 'Let Phong join?', deadline: '2026-11-09T00:00:00.000Z' })
      },
      '2026-11-03T00:00:00.000Z'
    );
    // a notice, a choice to someone else too, and one whose default names no option are not the phone's
    await m.writes('item', { to: [m.identityText], sealed: await sealed({ ...pausedItem, kind: 'notice' }) }, '2026-11-04T00:00:00.000Z');
    await m.writes('item', { to: [m.identityText, 'ed25519:other'], sealed: await sealed(pausedItem) }, '2026-11-04T00:00:00.000Z');
    await m.writes('item', { to: [m.identityText], sealed: await sealed({ ...pausedItem, default: 'nope' }) }, '2026-11-04T00:00:00.000Z');
    await m.writes('decision', await pickBody(m.enrollment.encryptionPublic, paused, 'unpause'), '2026-11-05T00:00:00.000Z');
    await m.writes('decision', await pickBody(m.enrollment.encryptionPublic, paused, 'stay_paused'), '2026-11-05T01:00:00.000Z');

    const read = await choices(m.enrollment, m.stored);
    expect(read.map((c) => [c.hash, c.subject, c.picked, c.deadline])).toEqual([
      [join, 'join', undefined, '2026-11-09T00:00:00.000Z'],
      [paused, 'paused', 'unpause', undefined]
    ]);
    expect(read[1]?.default).toBe('stay_paused');
  });

  it('writes a pick naming the choice under item, its option sealed to the member', async () => {
    const m = await member();
    const body = (await pickBody(m.enrollment.encryptionPublic, 'sha256:' + 'a'.repeat(64), 'unpause')) as Record<string, Json>;
    expect(Object.keys(body).sort()).toEqual(['item', 'sealed']);
    expect(body['item']).toBe('sha256:' + 'a'.repeat(64));
    expect(await openSealed(m.enrollment.encryption, m.enrollment.encryptionPublic, body['sealed'] as never)).toEqual({
      option: 'unpause'
    });
  });
});
