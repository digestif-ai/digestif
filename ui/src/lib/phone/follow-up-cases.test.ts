import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { importEncryptionKey, keyTextEd25519, keyTextX25519, seal, signEnvelope, type Json } from '#lib/mail.ts';
import { items } from './circle.ts';
import type { Enrollment } from './keystore.ts';
import type { Stored } from './relay.ts';

// DIG-556: the phone's copy of the follow-up rule, run over the cases the node's test generates
// (node/web/test/follow_up_cases.json; the node's test fails when the file is stale). Each case
// says whether every answer and pick counts, and `member` says whether it is by a reader, which is
// all the phone lists: it keeps and shows a late answer (DIG-87), so an answer is held to `member`
// and not to `counts`, which adds the node's time rule. The phone is held to the other half of that
// rule through `lapses`, which reads the author's closes and the answers inside the week. It sees
// an answer by anyone and only its own member's picks, so it is held to those. It reads a revoked
// key's cutoff (circle.ts, Key), but this test builds no revoked key, so a follow-up by one
// (leaver_in, leaver_out) is not written here and the lapse check of a question that has one is left out.
// DIG-99: the hand cases after the generated ones each sign a follow-up or a close at a time not in
// the Z form, which counts for nothing on both sides; an answer is still listed, in the order
// answer_order gives.

interface FollowUp {
  kind: 'answer' | 'pick';
  by: string;
  option: string;
  at: string;
  member: boolean;
  counts: boolean;
}
interface Close {
  by: 'author' | 'member';
  voice: 'person' | 'agent';
  closed: boolean;
  at: string;
}
interface Case {
  name: string;
  kind: 'question' | 'choice';
  to: 'circle' | 'named';
  asked: string;
  deadline: string | null;
  options: string[];
  follow_ups: FollowUp[];
  closes: Close[];
  lapses: boolean;
  /** A question its author's standing close closed. */
  closed: boolean;
  /** The answers listed, in order, by index into follow_ups (hand cases alone). */
  answer_order: number[] | null;
}

const corpus = JSON.parse(
  readFileSync(join(import.meta.dirname, '..', '..', '..', '..', 'node', 'web', 'test', 'follow_up_cases.json'), 'utf8')
) as { cases: Case[] };

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

const all: Stored[] = [];
async function write(p: Person, kind: string, body: Json, created_at?: string): Promise<string> {
  p.seq += 1;
  const { signed, hash } = await signEnvelope(
    p.device.privateKey,
    p.deviceRaw,
    { seq: p.seq, prev: p.prev, epoch: 1, kind, ...(created_at === undefined ? {} : { created_at }) },
    body
  );
  p.prev = hash;
  all.push({ relay_id: all.length + 1, hash, envelope: signed.envelope, body: signed.body as Json });
  return hash;
}

const sealed = async (to: Uint8Array<ArrayBuffer>[], p: unknown): Promise<Json> => (await seal(to, p)) as unknown as Json;

/** Admit [p] to the circle by a join on the dinner, and write its card. */
async function admit(p: Person, name: string): Promise<void> {
  const invite = await ed();
  const { signed, hash } = await signEnvelope(
    invite.privateKey,
    await raw(invite.publicKey),
    { seq: 1, epoch: 0, kind: 'join' },
    { dinner: all[0]?.hash ?? '', identity_key: p.identity, device_key: keyTextEd25519(p.deviceRaw) }
  );
  all.push({ relay_id: all.length + 1, hash, envelope: signed.envelope, body: signed.body as Json });
  await write(p, 'card', { name, agent_name: 'Juno', encryption_key: keyTextX25519(p.enc.publicRaw) });
}

describe('the phone holds the follow-up rule the node holds (DIG-556)', () => {
  it('agrees with every generated case it can read', async () => {
    const me = await person();
    const ada = await person();
    const ben = await person();
    const stranger = await person();
    await write(me, 'dinner', { host: me.identity, dinner: { date: '2026-10-27', label: 'x' }, guests: [], relays: [] });
    await admit(ada, 'Ada');
    await admit(ben, 'Ben');
    const e: Enrollment = { encryption: me.enc.privateKey, encryptionPublic: me.enc.publicRaw, identity: me.identity, relays: [] };
    const readers = [me.enc.publicRaw, ada.enc.publicRaw];

    const placed: { c: Case; item: string; hashes: (string | undefined)[] }[] = [];
    for (const c of corpus.cases) {
      const body = {
        kind: c.kind,
        title: c.name,
        detail: '',
        ...(c.kind === 'choice'
          ? {
              options: c.options.map((id) => ({ id, label: id, recommended: id === 'no' })),
              default: 'no',
              ...(c.deadline === null ? {} : { deadline: c.deadline })
            }
          : {})
      };
      const item = await write(
        ada,
        'item',
        c.to === 'circle' ? { to: 'circle', item: body } : { to: [me.identity], sealed: await sealed(readers, body) },
        c.asked
      );
      placed.push({ c, item, hashes: [] });
    }
    // The phone's people: the named member and, on the circle, a plain member are its own member.
    const who = (c: Case, by: string): Person | undefined =>
      by === 'author'
        ? ada
        : by === 'named'
          ? me
          : by === 'member'
            ? c.to === 'circle'
              ? me
              : ben
            : by === 'stranger'
              ? stranger
              : undefined;
    for (const p of placed) {
      // Written in the fixture's order: the phone orders picks by signed time itself, as the node does.
      p.hashes.length = p.c.follow_ups.length;
      for (const [i, f] of p.c.follow_ups.entries()) {
        const by = who(p.c, f.by);
        if (by === undefined) continue;
        const named = p.c.to === 'named';
        p.hashes[i] =
          f.kind === 'answer'
            ? await write(
                by,
                'item_answer',
                named
                  ? { item: p.item, to: [me.identity], sealed: await sealed(readers, { text: 'Thursday.', voice: 'person' }) }
                  : { item: p.item, text: 'Thursday.', voice: 'person' },
                f.at
              )
            : await write(by, 'decision', { item: p.item, sealed: await sealed(readers, { option: f.option }) }, f.at);
      }
    }
    // The author's closes and reopens, and a member's, which stand for nothing.
    for (const p of placed) {
      const named = p.c.to === 'named';
      for (const x of p.c.closes) {
        await write(
          x.by === 'author' ? ada : ben,
          'item_close',
          named
            ? { item: p.item, to: [me.identity], sealed: await sealed(readers, { closed: x.closed, voice: x.voice }) }
            : { item: p.item, closed: x.closed, voice: x.voice },
          x.at
        );
      }
    }
    const read = await items(e, all);
    for (const p of placed) {
      const got = read.find((i) => i.hash === p.item);
      expect(got, p.c.name).toBeDefined();
      if (got === undefined) continue;
      p.c.follow_ups.forEach((f, i) => {
        const h = p.hashes[i];
        if (h === undefined || f.kind !== 'answer') return;
        expect(
          got.answers.some((a) => a.hash === h),
          `${p.c.name}: answer ${i} by ${f.by} at ${f.at}`
        ).toBe(f.member);
      });
      // The phone judges only its own member's picks: the first that counts, in signed time then
      // hash as the node orders them, is the one it shows.
      if (p.c.kind === 'choice') {
        const mine = p.c.follow_ups
          .map((f, i) => ({ f, h: p.hashes[i] ?? '' }))
          .filter((x) => who(p.c, x.f.by) === me && x.f.counts)
          .sort((a, b) => Date.parse(a.f.at) - Date.parse(b.f.at) || (a.h < b.h ? -1 : a.h > b.h ? 1 : 0));
        expect(got.picked, `${p.c.name}: the member's pick`).toBe(mine[0]?.f.option);
      }
      if (p.c.kind === 'question' && !p.c.follow_ups.some((f) => f.by.startsWith('leaver'))) {
        expect(got.lapses !== undefined, `${p.c.name}: lapses`).toBe(p.c.lapses);
      }
      if (p.c.kind === 'question') {
        expect(got.closed, `${p.c.name}: closed by its author`).toBe(p.c.closed);
      }
      if (p.c.answer_order !== null) {
        expect(
          got.answers.map((a) => a.hash),
          `${p.c.name}: the answers in the follow-up order`
        ).toEqual(p.c.answer_order.map((i) => p.hashes[i]));
      }
    }
  });
});
