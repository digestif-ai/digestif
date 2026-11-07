import { describe, expect, it } from 'vitest';
import { importEncryptionKey, keyTextEd25519, keyTextX25519, openSealed, seal, signEnvelope, type Json } from '#lib/mail.ts';
import { items, itemDone, type PhoneItem } from './circle.ts';
import type { Enrollment } from './keystore.ts';
import { answerBody } from './phone.ts';
import type { Stored } from './relay.ts';

// The phone's Inbox read straight off envelopes (docs/protocol.md, Items, Picks): the member's
// node's own choices and notices, and another member's choice addressed to them.

const subtle = globalThis.crypto.subtle;
const raw = async (k: CryptoKey): Promise<Uint8Array<ArrayBuffer>> => new Uint8Array(await subtle.exportKey('raw', k));
const ed = async (): Promise<CryptoKeyPair> => (await subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify'])) as CryptoKeyPair;

interface Person {
  identity: string;
  device: CryptoKeyPair;
  deviceRaw: Uint8Array<ArrayBuffer>;
  enc: { privateKey: CryptoKey; publicRaw: Uint8Array<ArrayBuffer> };
  seq: number;
  prev?: string;
}

async function person(): Promise<Person> {
  const device = await ed();
  return {
    identity: keyTextEd25519(await raw((await ed()).publicKey)),
    device,
    deviceRaw: await raw(device.publicKey),
    enc: await importEncryptionKey(globalThis.crypto.getRandomValues(new Uint8Array(32))),
    seq: 0
  };
}

class Log {
  all: Stored[] = [];
  async write(p: Person, kind: string, body: Json, created_at?: string): Promise<string> {
    p.seq += 1;
    const { signed, hash } = await signEnvelope(
      p.device.privateKey,
      p.deviceRaw,
      { seq: p.seq, prev: p.prev, epoch: 1, kind, ...(created_at === undefined ? {} : { created_at }) },
      body
    );
    p.prev = hash;
    this.all.push({ relay_id: this.all.length + 1, hash, envelope: signed.envelope, body: signed.body as Json });
    return hash;
  }
}

const sealed = async (to: Uint8Array<ArrayBuffer>[], p: unknown): Promise<Json> => (await seal(to, p)) as unknown as Json;
const choice = (title: string, extra: Record<string, unknown> = {}) => ({
  kind: 'choice',
  title,
  detail: '',
  options: [
    { id: 'yes', label: 'Yes', recommended: true },
    { id: 'no', label: 'No' }
  ],
  default: 'no',
  ...extra
});

async function circle() {
  const me = await person();
  const ada = await person();
  const log = new Log();
  await log.write(me, 'dinner', { host: me.identity, dinner: { date: '2026-10-27', label: 'x' }, guests: [], relays: [] });
  const invite = await ed();
  const { signed, hash } = await signEnvelope(
    invite.privateKey,
    await raw(invite.publicKey),
    { seq: 1, epoch: 0, kind: 'join' },
    { dinner: log.all[0]?.hash ?? '', identity_key: ada.identity, device_key: keyTextEd25519(ada.deviceRaw) }
  );
  log.all.push({ relay_id: log.all.length + 1, hash, envelope: signed.envelope, body: signed.body as Json });
  await log.write(ada, 'card', { name: 'Ada', agent_name: 'Juno', encryption_key: keyTextX25519(ada.enc.publicRaw) });
  const e: Enrollment = { encryption: me.enc.privateKey, encryptionPublic: me.enc.publicRaw, identity: me.identity, relays: [] };
  return { me, ada, log, e };
}

const find = (all: PhoneItem[], title: string): PhoneItem => {
  const i = all.find((x) => x.title === title);
  if (i === undefined) throw new Error('no ' + title);
  return i;
};

describe('the phone reads the choices and notices sealed to the member', () => {
  it("reads the node's own choice and the member's first pick on it", async () => {
    const { me, log, e } = await circle();
    const h = await log.write(me, 'item', {
      to: [me.identity],
      sealed: await sealed([me.enc.publicRaw], choice('Keep Roman in?', { subject: 'join' }))
    });
    let read = find(await items(e, log.all), 'Keep Roman in?');
    expect(read).toMatchObject({ kind: 'choice', subject: 'join', default: 'no', author: me.identity, closed: false });
    expect(itemDone(read)).toBe(false);

    await log.write(me, 'decision', { item: h, sealed: await sealed([me.enc.publicRaw], { option: 'yes' }) });
    await log.write(me, 'decision', { item: h, sealed: await sealed([me.enc.publicRaw], { option: 'no' }) });
    read = find(await items(e, log.all), 'Keep Roman in?');
    expect(read.picked).toBe('yes');
    expect(itemDone(read)).toBe(true);
  });

  it("reads another member's choice with the card key a pick is sealed to, and seals the pick to both", async () => {
    const { me, ada, log, e } = await circle();
    await log.write(ada, 'item', {
      to: [me.identity],
      sealed: await sealed([me.enc.publicRaw, ada.enc.publicRaw], choice('Install it?', { subject: 'behavior' }))
    });
    const read = find(await items(e, log.all), 'Install it?');
    expect(read.author).toBe(ada.identity);
    expect(read.authorCard).toBe(keyTextX25519(ada.enc.publicRaw));

    const body = (await answerBody(e, read, 'yes')) as { item: string; sealed: Parameters<typeof openSealed>[2] };
    expect(body.item).toBe(read.hash);
    expect(await openSealed(ada.enc.privateKey, ada.enc.publicRaw, body.sealed)).toEqual({ option: 'yes' });
    expect(await openSealed(me.enc.privateKey, me.enc.publicRaw, body.sealed)).toEqual({ option: 'yes' });
  });

  it('refuses to write a pick on a choice whose author has no card', async () => {
    const { e } = await circle();
    const orphan: PhoneItem = {
      ...choice('x'),
      hash: 'sha256:1',
      kind: 'choice',
      options: [],
      created_at: '',
      author: 'ed25519:z',
      closed: false
    };
    expect(typeof (await answerBody(e, orphan, 'yes'))).toBe('string');
  });

  it('reads a notice as New until the member acknowledges it, sealed to them alone', async () => {
    const { me, log, e } = await circle();
    const h = await log.write(me, 'item', {
      to: [me.identity],
      sealed: await sealed([me.enc.publicRaw], { kind: 'notice', subject: 'note_ready', title: 'Note ready', detail: '' })
    });
    let read = find(await items(e, log.all), 'Note ready');
    expect(itemDone(read)).toBe(false);
    const body = (await answerBody(e, read, 'acknowledge')) as { sealed: { recipients: unknown[] } };
    expect(body.sealed.recipients).toHaveLength(1);
    await log.write(me, 'decision', body as unknown as Json);
    read = find(await items(e, log.all), 'Note ready');
    expect(read.picked).toBe('acknowledge');
    expect(log.all.at(-1)?.body).toMatchObject({ item: h });
  });

  it('leaves out an item addressed to someone else, a question, and a malformed choice', async () => {
    const { me, ada, log, e } = await circle();
    await log.write(ada, 'item', { to: [ada.identity], sealed: await sealed([me.enc.publicRaw, ada.enc.publicRaw], choice('Not mine')) });
    await log.write(ada, 'item', {
      to: [me.identity],
      sealed: await sealed([me.enc.publicRaw, ada.enc.publicRaw], { kind: 'question', title: 'A question', detail: '' })
    });
    await log.write(me, 'item', {
      to: [me.identity],
      sealed: await sealed([me.enc.publicRaw], choice('No default', { default: 'maybe' }))
    });
    expect(await items(e, log.all)).toEqual([]);
  });

  it("reads its author's close, the person's over the agent's, and ignores anyone else's", async () => {
    const { me, ada, log, e } = await circle();
    const h = await log.write(ada, 'item', {
      to: [me.identity],
      sealed: await sealed([me.enc.publicRaw, ada.enc.publicRaw], choice('Closable'))
    });
    const close = async (by: Person, closed: boolean, voice: string, at: string): Promise<void> => {
      await log.write(
        by,
        'item_close',
        { item: h, to: [me.identity], sealed: await sealed([me.enc.publicRaw, ada.enc.publicRaw], { closed, voice }) },
        at
      );
    };
    await close(me, true, 'person', '2026-11-01T00:00:00.000Z');
    expect(find(await items(e, log.all), 'Closable').closed).toBe(false);
    await close(ada, true, 'person', '2026-11-02T00:00:00.000Z');
    await close(ada, false, 'agent', '2026-11-03T00:00:00.000Z');
    expect(find(await items(e, log.all), 'Closable').closed).toBe(true);
  });

  it('ignores a pick after the deadline, and reads a deadline passed as Done', async () => {
    const { me, log, e } = await circle();
    const deadline = '2026-11-01T00:00:00.000Z';
    const h = await log.write(me, 'item', { to: [me.identity], sealed: await sealed([me.enc.publicRaw], choice('Late', { deadline })) });
    await log.write(me, 'decision', { item: h, sealed: await sealed([me.enc.publicRaw], { option: 'yes' }) }, '2026-11-02T00:00:00.000Z');
    const read = find(await items(e, log.all), 'Late');
    expect(read.picked).toBeUndefined();
    expect(itemDone(read, Date.parse('2026-11-03T00:00:00.000Z'))).toBe(true);
  });
});
