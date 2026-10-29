// Node cases: each builds relay histories on fresh local fake relays, runs the node's sync through
// the adapter contract, and checks what the node concluded. Two checked relays play honest relays
// that saw different subsets; an unchecked one plays a relay that accepted what it should not have.
import { answerBody, retractBody } from "../bodies.ts";
import { envelopeHash, signEnvelope } from "../envelope.ts";
import { accepted, check, equal, type Case } from "../harness.ts";
import { Signer } from "../keys.ts";
import type { NodeRunner } from "../node-runner.ts";
import type { NodeState } from "../reference-node.ts";
import type { World } from "../world.ts";
import { LINES } from "./lines.ts";

export interface NodeContext {
  /** The suite's circle on relays A and B, both checked. */
  world: World;
  a: string;
  b: string;
  /** An unchecked relay with the same root: accepts anything whose envelope signature verifies. */
  hostile: string;
  node: NodeRunner;
}

function sync(context: NodeContext, relays: string[]): Promise<NodeState> {
  return context.node.sync(context.world.host.device.signer, relays);
}

function key(state: NodeState, k: string) {
  return state.keys.find((s) => s.key === k);
}

export const nodeCases: Case<NodeContext>[] = [
  {
    id: "node.divergent.same-fold-and-feed",
    covers: LINES.divergent,
    title: "Relays holding the same envelopes in different orders, each missing some, sync to one fold and one feed in either relay order",
    async run(context) {
      const { world, a, b } = context;
      const [ix, iy] = await world.dinner(["divergent x", "divergent y"], [a, b]);
      const x = world.joinFor(ix!);
      const y = world.joinFor(iy!);
      await world.publish([a], x.member.device, x.signed, { unsigned: true });
      await world.publish([b], y.member.device, y.signed, { unsigned: true });
      const onlyA = await world.post(x.member.device, "x on A only", [a]);
      const onlyB = await world.post(y.member.device, "y on B only", [b]);
      await world.publish([a], y.member.device, y.signed, { unsigned: true });
      await world.publish([b], x.member.device, x.signed, { unsigned: true });
      const both = await world.post(x.member.device, "x on both", [a, b]);
      const ab = await sync(context, [a, b]);
      const ba = await sync(context, [b, a]);
      equal(ab, ba, "the node's state reading A then B, and B then A");
      for (const signed of [onlyA, onlyB, both]) check(ab.feed.includes(envelopeHash(signed.envelope)), `the feed holds ${envelopeHash(signed.envelope)}`);
      for (const k of [x.member.identity.key, x.member.device.key, y.member.identity.key, y.member.device.key]) check(key(ab, k) !== undefined, `the fold admits ${k}`);
      equal(ab.epoch, 2, "the epoch after two joins");
    },
  },
  {
    id: "node.gap.backfilled-from-other-relay",
    covers: LINES.gap,
    title: "A seq relay A is missing and relay B holds is backfilled, leaving no gap",
    async run(context) {
      const { world, a, b } = context;
      const [m] = await world.members(["gap"], [a, b]);
      const one = await world.post(m!.device, "gap 1", [a, b]);
      const two = await world.post(m!.device, "gap 2", [b]);
      const three = await world.post(m!.device, "gap 3", [a, b]);
      const state = await sync(context, [a, b]);
      equal(state.gaps.filter((g) => g.author === m!.device.key), [], "gaps for the member's device");
      equal(
        state.feed.filter((h) => [one, two, three].some((s) => envelopeHash(s.envelope) === h)),
        [one, two, three].map((s) => envelopeHash(s.envelope)),
        "the member's notes in the feed, in order",
      );
    },
  },
  {
    id: "node.gap.reported-when-unfilled",
    covers: LINES.gap,
    title: "A seq no relay holds is reported as a gap by author and seq",
    async run(context) {
      const { world, a, b } = context;
      const [m] = await world.members(["unfilled gap"], [a, b]);
      await world.post(m!.device, "gap 1", [a, b]);
      await world.post(m!.device, "gap 2", [b]);
      await world.post(m!.device, "gap 3", [a, b]);
      const state = await sync(context, [a]);
      equal(state.gaps.filter((g) => g.author === m!.device.key), [{ author: m!.device.key, missing: [2] }], "the gap reading relay A alone");
    },
  },
  {
    id: "node.duplicate.deduped",
    covers: LINES.duplicate,
    title: "An envelope served by two relays appears once",
    async run(context) {
      const { world, a, b } = context;
      const [m] = await world.members(["duplicate"], [a, b]);
      const note = await world.post(m!.device, "on both", [a, b]);
      const state = await sync(context, [a, b]);
      equal(state.feed.filter((h) => h === envelopeHash(note.envelope)).length, 1, "copies of the note in the feed");
    },
  },
  {
    id: "node.fork.surfaced",
    covers: LINES.duplicate,
    title: "Two relays each holding a different envelope at one author's seq is reported as a fork",
    async run(context) {
      const { world, a, b } = context;
      const [m] = await world.members(["fork"], [a, b]);
      const epoch = await world.epoch(a);
      const first = m!.device.peek("summary", { text: `fork first (${world.tag})` }, epoch);
      const second = m!.device.peek("summary", { text: `fork second (${world.tag})` }, epoch);
      await world.publish([a], m!.device, first);
      await world.publish([b], m!.device, second);
      const state = await sync(context, [a, b]);
      const hashes = [envelopeHash(first.envelope), envelopeHash(second.envelope)].sort();
      equal(state.faults.filter((f) => f.author === m!.device.key), [{ kind: "fork", author: m!.device.key, seq: 1, hashes }], "faults for the member's device");
      check(!hashes.every((h) => state.feed.includes(h)), "the node does not show both sides of the fork as ordinary notes");
    },
  },
  {
    id: "node.seq.mail-gaps-allowed",
    covers: LINES.sequence,
    title: "A mail key's out-of-order, gapped seqs are read without a gap or a fault",
    async run(context) {
      const { world, a, b } = context;
      const [m] = await world.members(["mail"], [a, b]);
      const mail = await world.addDevice(m!, "mail", [a, b]);
      const ask = await world.post(world.host.device, "the ask", [a, b], "question", answerBody("ask"));
      const epoch = await world.epoch(a);
      const answers = [5, 3].map((seq) =>
        signEnvelope(mail.signer, { kind: "answer", body: answerBody(`option ${seq}`), seq, prev: envelopeHash(ask.envelope), epoch }),
      );
      for (const answer of answers) await world.publish([a, b], mail, answer);
      const state = await sync(context, [a, b]);
      equal(state.gaps.filter((g) => g.author === mail.key), [], "gaps for the mail key");
      equal(state.faults.filter((f) => f.author === mail.key), [], "faults for the mail key");
      for (const answer of answers) check(state.feed.includes(envelopeHash(answer.envelope)), `the feed holds the answer at seq ${answer.envelope.seq}`);
    },
  },
  {
    id: "node.revocation.ignored-from-revoke-forward",
    covers: LINES.revocation,
    title:
      "A relay that never saw a revoke serves the revoked device's notes past the revoke's after_seq, one of them backdated before the revoke; the node keeps the notes at or below after_seq and ignores both",
    async run(context) {
      const { world, a, b } = context;
      const [m] = await world.members(["revoked device"], [a, b]);
      const lost = m!.device;
      const replacement = await world.addDevice(m!, "device", [a, b]);
      const before = await world.post(lost, "before the revoke", [a, b]);
      const onlyB = await world.post(lost, "before the revoke, on B only", [b]);
      const revokedAt = new Date(Date.now() + 1000);
      await world.publish([a], replacement, await world.revoke(replacement, m!.identity, lost.key, [lost], a, revokedAt));
      const after = await world.summary(lost, "after the revoke", b, new Date(revokedAt.getTime() + 1000));
      accepted((await world.appendTo([b], lost, after))[0]!, "relay B, which never saw the revoke, accepts the later note");
      // Earlier than the revoke and later than the device's admission: the one window a created_at
      // order would read it in.
      const backdatedAt = new Date(revokedAt.getTime() - 500);
      const backdated = await world.summary(lost, "backdated by a thief", b, backdatedAt);
      accepted((await world.appendTo([b], lost, backdated))[0]!, "relay B accepts the note a thief backdated before the revoke");
      const state = await sync(context, [b, a]);
      check(key(state, lost.key)?.revoked === true, "the fold marks the device revoked");
      check(state.feed.includes(envelopeHash(before.envelope)), "the note from before the revoke stays");
      check(state.feed.includes(envelopeHash(onlyB.envelope)), "the note at the revoke's after_seq, which only relay B holds, stays");
      check(!state.feed.includes(envelopeHash(after.envelope)), "the note from after the revoke is ignored");
      check(!state.feed.includes(envelopeHash(backdated.envelope)), "the note past after_seq is ignored though its created_at is before the revoke");
    },
  },
  {
    id: "node.revocation.mail-read-by-listed-hashes",
    covers: LINES.revocation,
    title:
      "A relay that never saw a revoke serves a revoked mail key's answers the revoke does not list, one of them backdated before the revoke; the node keeps the answers mail_read lists and ignores both",
    async run(context) {
      const { world, a, b } = context;
      const [m] = await world.members(["revoked mail key"], [a, b]);
      const mail = await world.addDevice(m!, "mail", [a, b]);
      const ask = await world.post(world.host.device, "the ask", [a, b], "question", answerBody("ask"));
      const epoch = await world.epoch(a);
      const answer = (seq: number, option: string, createdAt?: Date) =>
        signEnvelope(mail.signer, {
          kind: "answer",
          body: answerBody(option),
          seq,
          prev: envelopeHash(ask.envelope),
          epoch,
          ...(createdAt === undefined ? {} : { createdAt }),
        });
      const honest = answer(7, "honest");
      await world.publish([a, b], mail, honest);
      const onlyB = answer(3, "honest, on B only");
      await world.publish([b], mail, onlyB);
      const revokedAt = new Date(Date.now() + 1000);
      const mailRead = { [mail.key]: [envelopeHash(honest.envelope), envelopeHash(onlyB.envelope)] };
      await world.publish([a], m!.device, await world.revoke(m!.device, m!.identity, mail.key, [], a, revokedAt, mailRead));
      const after = answer(9, "after the revoke", new Date(revokedAt.getTime() + 1000));
      accepted((await world.appendTo([b], mail, after))[0]!, "relay B, which never saw the revoke, accepts the later answer");
      // A seq the honest key never used and a created_at between the key's admission and the revoke:
      // a merge-order cutoff would read it, and no seq cutoff can bound a chainless key.
      const backdated = answer(1, "backdated by a thief", new Date(revokedAt.getTime() - 500));
      accepted((await world.appendTo([b], mail, backdated))[0]!, "relay B accepts the answer a thief backdated before the revoke");
      const state = await sync(context, [b, a]);
      check(key(state, mail.key)?.revoked === true, "the fold marks the mail key revoked");
      check(state.feed.includes(envelopeHash(honest.envelope)), "the answer mail_read lists stays");
      check(state.feed.includes(envelopeHash(onlyB.envelope)), "the listed answer only relay B holds stays");
      check(!state.feed.includes(envelopeHash(after.envelope)), "the answer from after the revoke is ignored");
      check(!state.feed.includes(envelopeHash(backdated.envelope)), "the unlisted answer is ignored though its created_at is before the revoke");
    },
  },
  {
    id: "node.bootstrap.bad-joins-not-admitted",
    covers: LINES.bootstrap,
    title: "Joins from an unknown, a spent and an expired invite key, served by a relay that accepted them, are not admitted",
    async run(context) {
      const { world, a, hostile } = context;
      const [open] = await world.dinner(["valid guest"], [a, hostile]);
      const [expired] = await world.dinner(["late guest"], [a, hostile], { expired: true });
      const valid = world.joinFor(open!);
      await world.publish([a, hostile], valid.member.device, valid.signed, { unsigned: true });
      const spent = world.joinFor(open!);
      const unknown = world.joinFor({ name: "stranger", invite: Signer.random(), dinnerHash: open!.dinnerHash });
      const late = world.joinFor(expired!);
      for (const bad of [spent, unknown, late]) await world.publish([hostile], bad.member.device, bad.signed, { unsigned: true });
      const state = await sync(context, [hostile, a]);
      check(key(state, valid.member.identity.key)?.role === "identity", "the valid joiner is admitted");
      for (const [what, bad] of [["spent", spent], ["unknown", unknown], ["expired", late]] as const) {
        check(key(state, bad.member.identity.key) === undefined, `the ${what} invite's identity is not admitted`);
        check(key(state, bad.member.device.key) === undefined, `the ${what} invite's device is not admitted`);
      }
      equal(state.epoch, 1, "the epoch counts the one valid join");
    },
  },
  {
    id: "node.retract.author-only",
    covers: LINES.retract,
    title: "A retract from the author's identity hides the note; one from another identity, served by a relay that accepted it, does not",
    async run(context) {
      const { world, a, b, hostile } = context;
      const [m, other] = await world.members(["retract author", "retract interloper"], [a, b, hostile]);
      const second = await world.addDevice(m!, "device", [a, b, hostile]);
      const mine = await world.post(m!.device, "retracted by its author", [a, b, hostile]);
      const theirs = await world.post(m!.device, "not the interloper's to retract", [a, b, hostile]);
      const epoch = await world.epoch(a);
      await world.publish([a, b], second, second.next("retract", retractBody(envelopeHash(mine.envelope)), epoch));
      await world.publish([hostile], other!.device, other!.device.next("retract", retractBody(envelopeHash(theirs.envelope)), epoch));
      const state = await sync(context, [hostile, a, b]);
      check(!state.feed.includes(envelopeHash(mine.envelope)), "the note its author retracted is hidden");
      check(state.feed.includes(envelopeHash(theirs.envelope)), "the note another identity tried to retract stays");
    },
  },
];
