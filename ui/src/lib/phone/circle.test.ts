import { describe, expect, it } from 'vitest';
import { importEncryptionKey, keyTextEd25519, keyTextX25519, openSealed, seal, signEnvelope, type Json } from '#lib/mail.ts';
import { denyLayer, items, itemClosed, itemDone, type PhoneItem } from './circle.ts';
import type { Enrollment } from './keystore.ts';
import { answerBody, CIRCLE_ANSWER_ON_MACHINE, itemAnswerBody } from './phone.ts';
import type { Stored } from './relay.ts';

// The phone's Inbox read straight off envelopes (docs/protocol.md, Items, Picks): the member's
// node's own choices and notices, another member's choice addressed to them, the items addressed
// to the circle and the questions addressed to the member, with their answers.

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
      to: [e.identity],
      readers: [],
      options: [],
      created_at: '',
      author: 'ed25519:z',
      answers: [],
      answered: false,
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

  it("leaves out an item addressed to someone else, a malformed choice, an unknown kind and the member's own circle item", async () => {
    const { me, ada, log, e } = await circle();
    await log.write(ada, 'item', { to: [ada.identity], sealed: await sealed([me.enc.publicRaw, ada.enc.publicRaw], choice('Not mine')) });
    await log.write(me, 'item', {
      to: [me.identity],
      sealed: await sealed([me.enc.publicRaw], choice('No default', { default: 'maybe' }))
    });
    await log.write(ada, 'item', { to: 'circle', item: { kind: 'poll', title: 'Unknown kind', detail: '' } });
    await log.write(me, 'item', { to: 'circle', item: { kind: 'question', title: 'My own', detail: '' } });
    await log.write(ada, 'item', { to: [], sealed: await sealed([me.enc.publicRaw], choice('Empty to')) });
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

describe('the phone reads circle items and questions, and answers a question', () => {
  it('reads a circle question in the clear with its answers by readers, and leaves answering it to the machine until it shares its deny list', async () => {
    const { me, ada, log, e } = await circle();
    const h = await log.write(ada, 'item', {
      to: 'circle',
      item: { kind: 'question', title: 'Who has an eval set?', detail: 'For agents' }
    });
    let read = find(await items(e, log.all), 'Who has an eval set?');
    expect(read).toMatchObject({
      kind: 'question',
      to: 'circle',
      author: ada.identity,
      authorName: 'Ada',
      detail: 'For agents',
      answered: false
    });
    expect(itemDone(read)).toBe(false);

    expect(await itemAnswerBody(e, read, 'I do.')).toBe(CIRCLE_ANSWER_ON_MACHINE);

    // The member's machine answered it, through its deny layer.
    await log.write(me, 'item_answer', { item: h, text: 'I do.', voice: 'person' }, '2026-11-06T10:00:00.000Z');
    await log.write(ada, 'item_answer', { item: h, text: 'Thanks', voice: 'agent' }, '2026-11-06T10:00:01.000Z');
    read = find(await items(e, log.all), 'Who has an eval set?');
    expect(read.answers.map((a) => [a.author, a.text, a.voice])).toEqual([
      [me.identity, 'I do.', 'person'],
      [ada.identity, 'Thanks', 'agent']
    ]);
    expect(read.answers[1]).toMatchObject({ name: 'Ada', agentName: 'Juno' });
    expect(read.answered).toBe(true);
    expect(read.lapses).toBeUndefined();
    expect(itemDone(read)).toBe(true);
  });

  it("answers a circle question in the clear through the deny list the member's node shared", async () => {
    const { me, ada, log, e } = await circle();
    const h = await log.write(ada, 'item', { to: 'circle', item: { kind: 'question', title: 'Who has an eval set?', detail: '' } });
    const question = async () => find(await items(e, log.all), 'Who has an eval set?');
    const layer = async () => denyLayer(e, log.all);

    // Another member's deny list is not the member's, and opens for nobody here.
    await log.write(ada, 'deny_list', { sealed: await sealed([ada.enc.publicRaw], { entries: [] }) });
    expect(await layer()).toBeUndefined();

    await log.write(
      me,
      'deny_list',
      { sealed: await sealed([me.enc.publicRaw], { entries: [{ kind: 'name', value: 'Acme Corp' }] }) },
      '2026-11-01T00:00:00.000Z'
    );
    await log.write(
      me,
      'deny_list',
      {
        sealed: await sealed([me.enc.publicRaw], {
          entries: [
            { kind: 'name', value: 'Zed Corp' },
            { kind: 'name', value: 'Ada' }
          ]
        })
      },
      '2026-11-02T00:00:00.000Z'
    );
    const deny = await layer();
    expect(deny?.entries).toEqual([
      { kind: 'name', value: 'Zed Corp' },
      { kind: 'name', value: 'Ada' }
    ]);
    expect(deny?.allowed.sort()).toEqual(['Ada', 'Juno']);

    const read = await question();
    expect(await itemAnswerBody(e, read, 'We shipped it for zed corp.', deny)).toBe('Refused before signing: deny: name.');
    expect(await itemAnswerBody(e, read, 'Key AKIAABCDEFGHIJKLMNOP', deny)).toBe('Refused before signing: detector: Key and token shapes.');
    expect(await itemAnswerBody(e, read, 'Ask Acme Corp, they have one.', deny)).toEqual({
      item: h,
      text: 'Ask Acme Corp, they have one.',
      voice: 'person'
    });
    // A circle member's name never trips a name entry, as on the machine.
    const body = await itemAnswerBody(e, read, '  Ada has one.  ', deny);
    expect(body).toEqual({ item: h, text: 'Ada has one.', voice: 'person' });

    await log.write(me, 'item_answer', body as Json);
    const answered = await question();
    expect(answered.answers.map((a) => [a.author, a.text])).toEqual([[me.identity, 'Ada has one.']]);
    expect(itemDone(answered)).toBe(true);
  });

  it('checks a named answer against the shared deny list too, as the machine does', async () => {
    const { me, ada, log, e } = await circle();
    await log.write(ada, 'item', {
      to: [me.identity],
      sealed: await sealed([me.enc.publicRaw, ada.enc.publicRaw], { kind: 'question', title: 'Card?', detail: '' })
    });
    await log.write(me, 'deny_list', { sealed: await sealed([me.enc.publicRaw], { entries: [] }) });
    const deny = await denyLayer(e, log.all);
    const read = find(await items(e, log.all), 'Card?');
    expect(await itemAnswerBody(e, read, 'Mine is 4111 1111 1111 1111', deny)).toBe(
      'Refused before signing: detector: Payment card numbers.'
    );
    expect(await itemAnswerBody(e, read, 'No card here', deny)).toMatchObject({ to: [me.identity] });
  });

  it('reads a named question and seals the answer to every reader, its own to beside it', async () => {
    const { me, ada, log, e } = await circle();
    const h = await log.write(ada, 'item', {
      to: [me.identity],
      sealed: await sealed([me.enc.publicRaw, ada.enc.publicRaw], { kind: 'question', title: 'Intro me?', detail: '' })
    });
    const read = find(await items(e, log.all), 'Intro me?');
    expect(read.to).toEqual([me.identity]);
    expect(read.readers.map((r) => r.identity).sort()).toEqual([ada.identity, me.identity].sort());

    const body = (await itemAnswerBody(e, read, 'Sure')) as { item: string; to: string[]; sealed: Parameters<typeof openSealed>[2] };
    expect(body.item).toBe(h);
    expect(body.to).toEqual([me.identity]);
    expect(await openSealed(ada.enc.privateKey, ada.enc.publicRaw, body.sealed)).toEqual({ text: 'Sure', voice: 'person' });
    expect(await openSealed(me.enc.privateKey, me.enc.publicRaw, body.sealed)).toEqual({ text: 'Sure', voice: 'person' });

    await log.write(me, 'item_answer', body as unknown as Json);
    const again = find(await items(e, log.all), 'Intro me?');
    expect(again.answers).toHaveLength(1);
    expect(again.answers[0]).toMatchObject({ author: me.identity, text: 'Sure', voice: 'person' });
    expect(itemDone(again)).toBe(true);
  });

  it('refuses an empty answer, an answer to anything but a question, and a reader with no card', async () => {
    const { me, ada, log, e } = await circle();
    const stranger = await person();
    await log.write(ada, 'item', {
      to: [me.identity, stranger.identity],
      sealed: await sealed([me.enc.publicRaw, ada.enc.publicRaw], { kind: 'question', title: 'To two', detail: '' })
    });
    await log.write(ada, 'item', { to: 'circle', item: { kind: 'notice', title: 'A circle notice', detail: '' } });
    const all = await items(e, log.all);
    expect(await itemAnswerBody(e, find(all, 'To two'), 'Yes')).toBe('A member it is addressed to has no card to seal an answer to.');
    expect(typeof (await itemAnswerBody(e, find(all, 'A circle notice'), 'Yes'))).toBe('string');
    expect(typeof (await itemAnswerBody(e, find(all, 'To two'), '   '))).toBe('string');
  });

  it("ignores an answer by someone the question does not name, and reads its author's plaintext close on a circle item", async () => {
    const { me, ada, log, e } = await circle();
    const named = await log.write(me, 'item', {
      to: [me.identity],
      sealed: await sealed([me.enc.publicRaw], { kind: 'question', title: 'Just me', detail: '' })
    });
    await log.write(ada, 'item_answer', {
      item: named,
      to: [me.identity],
      sealed: await sealed([me.enc.publicRaw], { text: 'Butting in' })
    });
    expect(find(await items(e, log.all), 'Just me').answers).toEqual([]);

    const c = await log.write(ada, 'item', { to: 'circle', item: choice('Circle pick') });
    const read = find(await items(e, log.all), 'Circle pick');
    expect(read).toMatchObject({ kind: 'choice', to: 'circle', closed: false });
    await log.write(me, 'item_close', { item: c, closed: true, voice: 'person' });
    expect(find(await items(e, log.all), 'Circle pick').closed).toBe(false);
    await log.write(ada, 'item_close', { item: c, closed: true, voice: 'person' });
    expect(find(await items(e, log.all), 'Circle pick').closed).toBe(true);
  });

  it('closes a question nobody else answered a week after it was sent', async () => {
    const { ada, log, e } = await circle();
    await log.write(ada, 'item', { to: 'circle', item: { kind: 'question', title: 'Quiet', detail: '' } }, '2026-11-01T00:00:00.000Z');
    const read = find(await items(e, log.all), 'Quiet');
    expect(read.lapses).toBe('2026-11-08T00:00:00.000Z');
    expect(itemClosed(read, Date.parse('2026-11-07T00:00:00.000Z'))).toBe(false);
    expect(itemClosed(read, Date.parse('2026-11-09T00:00:00.000Z'))).toBe(true);
  });
});
