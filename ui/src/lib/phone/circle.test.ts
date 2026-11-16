import { describe, expect, it } from 'vitest';
import { b64url, importEncryptionKey, jcs, keyTextEd25519, keyTextX25519, openSealed, seal, signEnvelope, type Json } from '#lib/mail.ts';
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
  identityPair: CryptoKeyPair;
  device: CryptoKeyPair;
  deviceRaw: Uint8Array<ArrayBuffer>;
  enc: { privateKey: CryptoKey; publicRaw: Uint8Array<ArrayBuffer> };
  seq: number;
  prev?: string;
}

async function person(): Promise<Person> {
  const device = await ed();
  const identityPair = await ed();
  return {
    identity: keyTextEd25519(await raw(identityPair.publicKey)),
    identityPair,
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

describe("the asker's reopen and the clock, and times with fractions (DIG-544, DIG-555)", () => {
  const after = Date.parse('2026-11-12T00:00:00.000Z');
  const ask = async (log: Log, ada: Person, title: string) =>
    log.write(ada, 'item', { to: 'circle', item: { kind: 'question', title, detail: '' } }, '2026-11-01T00:00:00.000Z');

  it('opens a lapsed question when its asker reopens it, after a late answer or none', async () => {
    const { me, ada, log, e } = await circle();
    const late = await ask(log, ada, 'Late then reopened');
    const none = await ask(log, ada, 'None then reopened');
    await log.write(me, 'item_answer', { item: late, text: 'Too late', voice: 'person' }, '2026-11-09T00:00:00.000Z');
    expect(itemClosed(find(await items(e, log.all), 'Late then reopened'), after)).toBe(true);
    await log.write(ada, 'item_close', { item: late, closed: false, voice: 'person' }, '2026-11-10T00:00:00.000Z');
    await log.write(ada, 'item_close', { item: none, closed: false, voice: 'person' }, '2026-11-10T00:00:00.000Z');
    const read = await items(e, log.all);
    expect(itemClosed(find(read, 'Late then reopened'), after)).toBe(false);
    expect(itemClosed(find(read, 'None then reopened'), after)).toBe(false);
  });

  it('counts a pick 500 ms after a whole-second deadline as late', async () => {
    const { me, log, e } = await circle();
    const deadline = '2026-11-01T10:00:00Z';
    const h = await log.write(me, 'item', { to: [me.identity], sealed: await sealed([me.enc.publicRaw], choice('Whole', { deadline })) });
    await log.write(me, 'decision', { item: h, sealed: await sealed([me.enc.publicRaw], { option: 'yes' }) }, '2026-11-01T10:00:00.500Z');
    expect(find(await items(e, log.all), 'Whole').picked).toBeUndefined();
  });

  it('orders a close and a reopen by the bytes of their times, as the node does', async () => {
    const { ada, log, e } = await circle();
    const h = await ask(log, ada, 'Mixed');
    await log.write(ada, 'item_close', { item: h, closed: true, voice: 'person' }, '2026-11-02T10:00:00Z');
    await log.write(ada, 'item_close', { item: h, closed: false, voice: 'person' }, '2026-11-02T10:00:00.500Z');
    // 'Z' sorts after '.', so the whole-second close stands, on the node and here.
    expect(find(await items(e, log.all), 'Mixed').closed).toBe(true);
  });

  it('refuses seconds of 60 and a fraction of more than three digits', async () => {
    const { me, log, e } = await circle();
    const one = async (deadline: string) => {
      await log.write(me, 'item', { to: [me.identity], sealed: await sealed([me.enc.publicRaw], choice('T' + deadline, { deadline })) });
      return (await items(e, log.all)).some((i) => i.title === 'T' + deadline);
    };
    expect(await one('2026-12-01T10:00:00.5Z')).toBe(true);
    expect(await one('2026-12-01T10:00:00.123Z')).toBe(true);
    expect(await one('2026-12-01T10:00:60Z')).toBe(false);
    expect(await one('2026-12-01T10:00:00.1234Z')).toBe(false);
  });
});

describe('a choice whose deadline is not in the Z form (DIG-555)', () => {
  const titles = async (deadline: unknown, extra: Record<string, unknown> = {}): Promise<string[]> => {
    const { me, log, e } = await circle();
    await log.write(me, 'item', { to: [me.identity], sealed: await sealed([me.enc.publicRaw], choice('Timed', { deadline, ...extra })) });
    return (await items(e, log.all)).map((i) => i.title);
  };

  it('reads the Z form, with and without a fraction', async () => {
    expect(await titles('2026-12-01T10:00:00Z')).toEqual(['Timed']);
    expect(await titles('2026-12-01T10:00:00.250Z')).toEqual(['Timed']);
  });

  it('leaves out an item with an offset, no zone, a bare date, an empty string or a number', async () => {
    for (const d of ['2026-12-01T10:00:00+01:00', '2026-12-01T10:00:00', '2026-12-01', '', 5]) {
      expect(await titles(d), String(d)).toEqual([]);
    }
  });

  it('reads a choice with no deadline, and a notice that carries a stray one', async () => {
    expect(await titles(undefined)).toEqual(['Timed']);
    expect(await titles('2026-12-01', { kind: 'notice' })).toEqual(['Timed']);
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

  it('counts only an answer signed inside the week (DIG-544)', async () => {
    const { me, ada, log, e } = await circle();
    const asked = '2026-11-01T00:00:00.000Z';
    const late = await log.write(ada, 'item', { to: 'circle', item: { kind: 'question', title: 'Late', detail: '' } }, asked);
    const early = await log.write(ada, 'item', { to: 'circle', item: { kind: 'question', title: 'Early', detail: '' } }, asked);
    const edge = await log.write(ada, 'item', { to: 'circle', item: { kind: 'question', title: 'Edge', detail: '' } }, asked);
    // Day 8, before anything else arrives: it is listed and the question stays closed by the clock.
    await log.write(me, 'item_answer', { item: late, text: 'Too late', voice: 'person' }, '2026-11-09T00:00:00.000Z');
    // Signed on day 6 but written to the log after the day 8 one: the signed time decides.
    await log.write(me, 'item_answer', { item: early, text: 'In time', voice: 'person' }, '2026-11-07T00:00:00.000Z');
    // Signed at the lapse itself: not before it, so it does not count.
    await log.write(me, 'item_answer', { item: edge, text: 'At the line', voice: 'person' }, '2026-11-08T00:00:00.000Z');
    const read = await items(e, log.all);
    expect(find(read, 'Late').answers.map((a) => a.text)).toEqual(['Too late']);
    expect(find(read, 'Late').lapses).toBe('2026-11-08T00:00:00.000Z');
    expect(itemClosed(find(read, 'Late'), Date.parse('2026-11-12T00:00:00.000Z'))).toBe(true);
    expect(find(read, 'Early').lapses).toBeUndefined();
    expect(itemClosed(find(read, 'Early'), Date.parse('2026-11-12T00:00:00.000Z'))).toBe(false);
    expect(find(read, 'Edge').lapses).toBe('2026-11-08T00:00:00.000Z');
  });

  it('counts no answer whose signed time is not in the Z form, as the node (DIG-91)', async () => {
    const { me, ada, log, e } = await circle();
    const asked = '2026-11-01T00:00:00.000Z';
    const times: [string, string][] = [
      ['an offset', '2026-11-03T00:00:00+00:00'],
      ['no zone', '2026-11-03T00:00:00'],
      ['garbage', 'not a time'],
      ['the 31st of February', '2026-02-31T10:00:00Z']
    ];
    for (const [title, at] of times) {
      const q = await log.write(ada, 'item', { to: 'circle', item: { kind: 'question', title, detail: '' } }, asked);
      await log.write(me, 'item_answer', { item: q, text: 'Thursday', voice: 'person' }, at);
    }
    const read = await items(e, log.all);
    for (const [title] of times) {
      expect(find(read, title).answers.map((a) => a.text)).toEqual(['Thursday']);
      expect(find(read, title).lapses).toBe('2026-11-08T00:00:00.000Z');
    }
  });
});

// A revoked key is read by its cutoff, as the node's fold reads it (docs/protocol.md, revoke;
// node/core/fold.ml, within_cutoff, author_in_force): a device key at or below after_seq and none
// above, a mail key the envelopes mail_read lists and no other.
describe('a revoked key is read by its cutoff (DIG-92)', () => {
  const sign = async (k: CryptoKey, claim: unknown): Promise<string> =>
    b64url(new Uint8Array(await subtle.sign({ name: 'Ed25519' }, k, new TextEncoder().encode(jcs(claim)))));

  /** A key that writes envelopes: a device's chain, or a chainless mail key's seq of choice. */
  interface Writer {
    pair: CryptoKeyPair;
    raw: Uint8Array<ArrayBuffer>;
    text: string;
    seq: number;
    prev?: string;
  }
  const writer = async (): Promise<Writer> => {
    const pair = await ed();
    const r = await raw(pair.publicKey);
    return { pair, raw: r, text: keyTextEd25519(r), seq: 0 };
  };
  async function write(log: Log, w: Writer, kind: string, body: Json, seq?: number): Promise<string> {
    w.seq = seq ?? w.seq + 1;
    const { signed, hash } = await signEnvelope(
      w.pair.privateKey,
      w.raw,
      { seq: w.seq, prev: seq === undefined ? w.prev : undefined, epoch: 1, kind },
      body
    );
    if (seq === undefined) w.prev = hash;
    log.all.push({ relay_id: log.all.length + 1, hash, envelope: signed.envelope, body: signed.body as Json });
    return hash;
  }

  /** Bo, a guest of the founding dinner: an identity whose phrase signs, and the device its join admitted. */
  async function withBo() {
    const c = await circle();
    const identity = await writer();
    const device = await writer();
    const invite = await writer();
    await write(c.log, invite, 'join', { dinner: c.log.all[0]?.hash ?? '', identity_key: identity.text, device_key: device.text });
    const bo = { identity, device };
    const question = await c.log.write(c.ada, 'item', { to: 'circle', item: { kind: 'question', title: 'Anyone?', detail: '' } });
    return { ...c, bo, question };
  }
  async function admit(log: Log, author: Writer, identity: Writer, role: 'device' | 'mail'): Promise<Writer> {
    const k = await writer();
    const claim = { identity_key: identity.text, key: k.text, role };
    await write(log, author, 'device', { ...claim, signature: await sign(identity.pair.privateKey, claim) });
    return k;
  }
  async function revoke(
    log: Log,
    author: Writer | Person,
    by: CryptoKey,
    claim: { target: string; by: string; after_seq: Json; mail_read: Json }
  ) {
    const body = { ...claim, signature: await sign(by, claim) };
    return 'pair' in author ? write(log, author, 'revoke', body) : log.write(author, 'revoke', body);
  }
  const answer = (log: Log, w: Writer, item: string, text: string, seq?: number) =>
    write(log, w, 'item_answer', { item, text, voice: 'person' }, seq);
  const said = async (e: Enrollment, log: Log) => find(await items(e, log.all), 'Anyone?');

  it("counts a device key's answer at its after_seq and drops the one past it", async () => {
    const { me, log, e, bo, question } = await withBo();
    await answer(log, bo.device, question, 'At the cutoff'); // seq 1
    await answer(log, bo.device, question, 'Past it'); // seq 2
    await revoke(log, me, me.identityPair.privateKey, {
      target: bo.identity.text,
      by: me.identity,
      after_seq: { [bo.device.text]: 1 },
      mail_read: {}
    });
    const read = await said(e, log);
    expect(read.answers.map((a) => [a.author, a.text])).toEqual([[bo.identity.text, 'At the cutoff']]);
    expect(read.lapses).toBeUndefined();
  });

  it('drops every answer of a device key the revoke stops and does not list: a cutoff of 0', async () => {
    const { me, log, e, bo, question } = await withBo();
    await answer(log, bo.device, question, 'Unlisted');
    await revoke(log, me, me.identityPair.privateKey, {
      target: bo.identity.text,
      by: me.identity,
      after_seq: {},
      mail_read: {}
    });
    const read = await said(e, log);
    expect(read.answers).toEqual([]);
    expect(read.lapses).toBeDefined();
  });

  it("counts a mail key's answer mail_read lists and drops one it does not, whatever its seq", async () => {
    const { me, log, e, bo, question } = await withBo();
    const mail = await admit(log, bo.device, bo.identity, 'mail');
    const listed = await answer(log, mail, question, 'Listed', 900);
    await answer(log, mail, question, 'Not listed', 1);
    await revoke(log, me, me.identityPair.privateKey, {
      target: bo.identity.text,
      by: me.identity,
      after_seq: { [bo.device.text]: 1 },
      mail_read: { [mail.text]: [listed] }
    });
    expect((await said(e, log)).answers.map((a) => a.text)).toEqual(['Listed']);
  });

  it('keeps the lower after_seq and the hashes both revokes list', async () => {
    const { me, log, e, bo, question } = await withBo();
    const mail = await admit(log, bo.device, bo.identity, 'mail'); // device seq 1
    await answer(log, bo.device, question, 'Seq 2'); // seq 2
    await answer(log, bo.device, question, 'Seq 3'); // seq 3
    await answer(log, bo.device, question, 'Seq 4'); // seq 4, past both cutoffs
    const m1 = await answer(log, mail, question, 'Mail one', 5);
    const m2 = await answer(log, mail, question, 'Mail two', 6);
    await answer(log, mail, question, 'Mail three', 7);
    await revoke(log, me, me.identityPair.privateKey, {
      target: bo.identity.text,
      by: me.identity,
      after_seq: { [bo.device.text]: 3 },
      mail_read: { [mail.text]: [m1, m2] }
    });
    expect((await said(e, log)).answers.map((a) => a.text).sort()).toEqual(['Mail one', 'Mail two', 'Seq 2', 'Seq 3']);
    // A second revoke of Bo, with a lower cutoff and fewer hashes: the stricter of the two stands.
    await revoke(log, me, me.identityPair.privateKey, {
      target: bo.identity.text,
      by: me.identity,
      after_seq: { [bo.device.text]: 2 },
      mail_read: { [mail.text]: [m2] }
    });
    expect((await said(e, log)).answers.map((a) => a.text).sort()).toEqual(['Mail two', 'Seq 2']);
  });

  it('leaves out a key a revoked device admitted past its cutoff, and keeps one it admitted inside it, as the fold reruns', async () => {
    const { log, e, bo, question } = await withBo();
    const kept = await admit(log, bo.device, bo.identity, 'device'); // bo.device seq 1
    await revoke(log, kept, bo.identity.pair.privateKey, {
      target: bo.device.text,
      by: bo.identity.text,
      after_seq: { [bo.device.text]: 1 },
      mail_read: {}
    });
    const late = await admit(log, bo.device, bo.identity, 'device'); // bo.device seq 2, past the cutoff
    await answer(log, kept, question, 'Kept');
    await answer(log, late, question, 'Late');
    expect((await said(e, log)).answers.map((a) => a.text)).toEqual(['Kept']);
  });

  it('ignores a revoke no node applies: not signed by its by, naming a key it does not stop, or by someone with no say', async () => {
    const { me, ada, log, e, bo, question } = await withBo();
    await answer(log, bo.device, question, 'Still here');
    const stranger = await ed();
    await revoke(log, me, stranger.privateKey, { target: bo.identity.text, by: me.identity, after_seq: {}, mail_read: {} });
    await revoke(log, me, me.identityPair.privateKey, {
      target: bo.identity.text,
      by: me.identity,
      after_seq: { [keyTextEd25519(ada.deviceRaw)]: 0 },
      mail_read: {}
    });
    // Ada did not host the dinner that admitted Bo.
    await revoke(log, ada, ada.identityPair.privateKey, { target: bo.identity.text, by: ada.identity, after_seq: {}, mail_read: {} });
    expect((await said(e, log)).answers.map((a) => a.text)).toEqual(['Still here']);
  });
});
