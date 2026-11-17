import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { b64url, importEncryptionKey, jcs, keyTextEd25519, keyTextX25519, seal, signEnvelope, type Json } from '#lib/mail.ts';
import { items } from './circle.ts';
import type { Enrollment } from './keystore.ts';
import type { Stored } from './relay.ts';

// DIG-556, DIG-100: the phone's copy of the follow-up rule, run over the cases the node's test
// generates (node/web/test/follow_up_cases.json; the node's test fails when the file is stale). Each
// case says of every answer and pick whether it is a reader's (`member`) and whether it counts
// (`counts`, which for an answer adds the node's time rule, DIG-87), of every close whether it is
// its author's, whether the author's close that stands closes it, whether the question lapses, and
// each reader's pick as the node made it. The phone keeps and shows a late answer, so an answer is
// held to `member`; it is held to the time rule through `lapses`. Every role is played by whom the
// node's test plays it with: the phone's member is the node's own member (`own`), a revoked key is
// a second device its identity admitted and revoked with the same cutoff, and `late` is a device
// whose admission comes after its follow-ups. The phone sees an answer by anyone and only its own
// member's picks, so it is held to those.
// DIG-99: the hand cases after the others each sign a follow-up or a close at a time not in the
// Z form, which counts for nothing on both sides; an answer is still listed, in the order
// answer_order gives.
// DIG-88: `closes_at` is when the item closes by the clock while no close of its author stands: a
// question's lapse, from its asking or from the reopen that stands; a choice's deadline, and once
// reopened the earlier of its deadline and a week after the reopen.
// DIG-102: the last cases are items signed at a time not in the Z form (`readable` false), which
// neither side reads, so nothing on them counts.

interface FollowUp {
  kind: 'answer' | 'pick';
  by: string;
  option: string;
  at: string;
  member: boolean;
  counts: boolean;
}
interface Close {
  by: string;
  voice: 'person' | 'agent';
  closed: boolean;
  at: string;
  counts: boolean;
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
  /** The author's close that stands closes it. */
  closed: boolean;
  /** When it closes by the clock, with no close of its author standing (DIG-88). */
  closes_at: string | null;
  picked: Record<string, string>;
  /** The answers listed, in order, by index into follow_ups (hand cases alone). */
  answer_order: number[] | null;
  /** The item is signed at a time in the Z form; one that is not is unreadable (DIG-102). */
  readable: boolean;
}

const corpus = JSON.parse(
  readFileSync(join(import.meta.dirname, '..', '..', '..', '..', 'node', 'web', 'test', 'follow_up_cases.json'), 'utf8')
) as { cases: Case[] };

const subtle = globalThis.crypto.subtle;
const raw = async (k: CryptoKey): Promise<Uint8Array<ArrayBuffer>> => new Uint8Array(await subtle.exportKey('raw', k));
const ed = async (): Promise<CryptoKeyPair> => (await subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify'])) as CryptoKeyPair;
const sign = async (k: CryptoKey, claim: unknown): Promise<string> =>
  b64url(new Uint8Array(await subtle.sign({ name: 'Ed25519' }, k, new TextEncoder().encode(jcs(claim)))));

/** A device of an identity: its chain, and the identity's own key, which signs admissions and revokes. */
interface Person {
  identity: string;
  identityPair: CryptoKeyPair;
  device: CryptoKeyPair;
  deviceRaw: Uint8Array<ArrayBuffer>;
  deviceText: string;
  enc: { privateKey: CryptoKey; publicRaw: Uint8Array<ArrayBuffer> };
  seq: number;
  prev?: string | undefined;
}

async function device(): Promise<Pick<Person, 'device' | 'deviceRaw' | 'deviceText' | 'seq'>> {
  const d = await ed();
  const r = await raw(d.publicKey);
  return { device: d, deviceRaw: r, deviceText: keyTextEd25519(r), seq: 0 };
}

async function person(): Promise<Person> {
  const identityPair = await ed();
  return {
    identity: keyTextEd25519(await raw(identityPair.publicKey)),
    identityPair,
    ...(await device()),
    enc: await importEncryptionKey(globalThis.crypto.getRandomValues(new Uint8Array(32)))
  };
}

const all: Stored[] = [];

/** The envelope [p] would write next, signed and chained but not appended. */
async function signed(p: Person, kind: string, body: Json, created_at?: string) {
  return signEnvelope(
    p.device.privateKey,
    p.deviceRaw,
    { seq: p.seq + 1, prev: p.prev, epoch: 1, kind, ...(created_at === undefined ? {} : { created_at }) },
    body
  );
}

function append(p: Person, s: Awaited<ReturnType<typeof signEnvelope>>): string {
  p.seq += 1;
  p.prev = s.hash;
  all.push({ relay_id: all.length + 1, hash: s.hash, envelope: s.signed.envelope, body: s.signed.body as Json });
  return s.hash;
}

const write = async (p: Person, kind: string, body: Json, created_at?: string): Promise<string> =>
  append(p, await signed(p, kind, body, created_at));

const sealed = async (to: Uint8Array<ArrayBuffer>[], p: unknown): Promise<Json> => (await seal(to, p)) as unknown as Json;

/** Admit [p] to the circle by a join on the dinner, and write its card. */
async function admit(p: Person, name: string): Promise<void> {
  const invite = await ed();
  const join = await signEnvelope(
    invite.privateKey,
    await raw(invite.publicKey),
    { seq: 1, epoch: 0, kind: 'join' },
    { dinner: all[0]?.hash ?? '', identity_key: p.identity, device_key: p.deviceText }
  );
  all.push({ relay_id: all.length + 1, hash: join.hash, envelope: join.signed.envelope, body: join.signed.body as Json });
  await write(p, 'card', { name, agent_name: 'Juno', encryption_key: keyTextX25519(p.enc.publicRaw) });
}

/** A second device of [p], admitted by a device envelope [by] writes under [p]'s identity signature, now or later. */
async function secondDevice(p: Person, by: Person): Promise<{ d: Person; admission: () => Promise<string> }> {
  const d: Person = { ...p, ...(await device()), prev: undefined };
  const claim = { identity_key: p.identity, key: d.deviceText, role: 'device' };
  const body = { ...claim, signature: await sign(p.identityPair.privateKey, claim) };
  return { d, admission: () => write(by, 'device', body) };
}

/** [p]'s identity revokes its device [d], reading it up to [after] (docs/protocol.md, revoke). */
async function revoke(p: Person, d: Person, after: number): Promise<void> {
  const claim = { target: d.deviceText, by: p.identity, after_seq: { [d.deviceText]: after }, mail_read: {} };
  await write(p, 'revoke', { ...claim, signature: await sign(p.identityPair.privateKey, claim) });
}

// Whose a role's key is, as identity_of_role in the node's test: one identity's picks share a first pick.
const identityOf = (by: string): string =>
  by.startsWith('author') ? 'author' : by === 'late' ? 'member' : by.startsWith('leaver') ? 'leaver' : by;

describe('the phone holds the follow-up rule the node holds (DIG-556, DIG-100)', () => {
  it('agrees with every generated case', async () => {
    const me = await person();
    const ada = await person();
    const quinn = await person();
    const ben = await person();
    const leaver = await person();
    const stranger = await person();
    await write(me, 'dinner', { host: me.identity, dinner: { date: '2026-10-27', label: 'x' }, guests: [], relays: [] });
    await admit(ada, 'Ada');
    await admit(quinn, 'Quinn');
    await admit(ben, 'Ben');
    await admit(leaver, 'Lee');
    const leaver2 = await secondDevice(leaver, leaver);
    await leaver2.admission();
    const ada3 = await secondDevice(ada, ada);
    await ada3.admission();
    const late = await secondDevice(ben, ben);
    const e: Enrollment = { encryption: me.enc.privateKey, encryptionPublic: me.enc.publicRaw, identity: me.identity, relays: [] };
    const named = [me.identity, quinn.identity];
    const readers = [me.enc.publicRaw, ada.enc.publicRaw, quinn.enc.publicRaw];
    const people: Record<string, Person> = {
      author: ada,
      named: quinn,
      member: ben,
      stranger,
      leaver_in: leaver2.d,
      leaver_out: leaver2.d,
      late: late.d,
      own: me,
      author_in: ada3.d,
      author_out: ada3.d
    };

    const placed: { c: Case; item: string; hashes: (string | undefined)[] }[] = [];
    for (const c of corpus.cases) {
      const body = {
        kind: c.kind,
        title: c.name,
        detail: '',
        ...(c.kind === 'choice'
          ? {
              options: c.options.map((id) => ({ id, label: id, recommended: false })),
              default: 'no',
              ...(c.deadline === null ? {} : { deadline: c.deadline })
            }
          : {})
      };
      const item = await write(
        ada,
        'item',
        c.to === 'circle' ? { to: 'circle', item: body } : { to: named, sealed: await sealed(readers, body) },
        c.asked
      );
      placed.push({ c, item, hashes: [] });
    }

    // Of two picks by one reader at one signed time, the one listed later is written with the
    // smaller hash, as the node's test writes them: a pick is sealed afresh until it falls there.
    async function followUp(p: (typeof placed)[number], i: number): Promise<void> {
      const f = p.c.follow_ups[i];
      const by = f === undefined ? undefined : people[f.by];
      if (f === undefined || by === undefined) throw new Error(`${p.c.name}: no one plays ${f?.by}`);
      const circle = p.c.to === 'circle';
      const fields = { text: 'Thursday.', voice: 'person' };
      const body = async (): Promise<Json> =>
        f.kind === 'pick'
          ? { item: p.item, sealed: await sealed(readers, { option: f.option }) }
          : circle
            ? { item: p.item, ...fields }
            : { item: p.item, to: named, sealed: await sealed(readers, fields) };
      const kind = f.kind === 'answer' ? 'item_answer' : 'decision';
      const ties = p.c.follow_ups.flatMap((g, j) => {
        const h = p.hashes[j];
        return j !== i &&
          h !== undefined &&
          f.kind === 'pick' &&
          g.kind === 'pick' &&
          g.at === f.at &&
          identityOf(g.by) === identityOf(f.by)
          ? [(x: string) => (i > j ? x < h : x > h)]
          : [];
      });
      for (;;) {
        const s = await signed(by, kind, await body(), f.at);
        if (ties.every((ok) => ok(s.hash))) {
          p.hashes[i] = append(by, s);
          return;
        }
      }
    }
    /** A close or reopen by the author, a revoked key of theirs, or a member (which stands for nothing). */
    async function close(p: (typeof placed)[number], x: Close): Promise<void> {
      const by = people[x.by];
      if (by === undefined) throw new Error(`${p.c.name}: no one plays ${x.by}`);
      const fields = { closed: x.closed, voice: x.voice };
      await write(
        by,
        'item_close',
        p.c.to === 'circle' ? { item: p.item, ...fields } : { item: p.item, to: named, sealed: await sealed(readers, fields) },
        x.at
      );
    }
    // Every write inside a cutoff before every write past it, since a cutoff is a seq.
    for (const pass of [true, false])
      for (const p of placed) {
        for (let i = 0; i < p.c.follow_ups.length; i++) if ((p.c.follow_ups[i]?.by === 'leaver_in') === pass) await followUp(p, i);
        for (const x of p.c.closes) if ((x.by === 'author_in') === pass) await close(p, x);
      }
    const count = (by: string) =>
      corpus.cases.flatMap((c) => [...c.follow_ups.map((f) => f.by), ...c.closes.map((x) => x.by)]).filter((b) => b === by).length;
    await revoke(leaver, leaver2.d, count('leaver_in'));
    await revoke(ada, ada3.d, count('author_in'));
    // The late device's admission reaches the log after everything it signed.
    await late.admission();

    const read = await items(e, all);
    for (const p of placed) {
      const got = read.find((i) => i.hash === p.item);
      if (!p.c.readable) {
        expect(got, `${p.c.name}: unreadable`).toBeUndefined();
        continue;
      }
      expect(got, p.c.name).toBeDefined();
      if (got === undefined) continue;
      p.c.follow_ups.forEach((f, i) => {
        const h = p.hashes[i];
        if (f.kind !== 'answer') return;
        expect(
          got.answers.some((a) => a.hash === h),
          `${p.c.name}: answer ${i} by ${f.by} at ${f.at}`
        ).toBe(f.member);
      });
      expect(got.picked, `${p.c.name}: the member's pick, as the node made it`).toBe(p.c.picked['own']);
      expect(got.closed, `${p.c.name}: the author's close that stands closes it`).toBe(p.c.closed);
      if (p.c.kind === 'question') expect(got.lapses !== undefined, `${p.c.name}: lapses`).toBe(p.c.lapses);
      if (!p.c.closed) {
        const at = got.lapses ?? (got.kind === 'choice' ? got.deadline : undefined);
        expect(at === undefined ? null : Date.parse(at), `${p.c.name}: closes by the clock at`).toBe(
          p.c.closes_at === null ? null : Date.parse(p.c.closes_at)
        );
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
