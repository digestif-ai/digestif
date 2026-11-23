// Node cases: each builds relay histories on fresh local fake relays, runs the node's sync through
// the adapter contract, and checks what the node concluded. Two checked relays play honest relays
// that saw different subsets; an unchecked one plays a relay that accepted what it should not have.
import { keepId, namedItemBody, pickBody, retractBody, signKeep, summaryBody, type Keep } from "../bodies.ts";
import { isoTime, jcs } from "../encoding.ts";
import { envelopeHash, signEnvelope, unsignedPart, type Author, type SignedEnvelope } from "../envelope.ts";
import { accepted, check, equal, type Case } from "../harness.ts";
import { Signer } from "../keys.ts";
import type { NodeRunner } from "../node-runner.ts";
import type { NodeState } from "../reference-node.ts";
import { EncryptionKey, seal } from "../sealing.ts";
import type { World } from "../world.ts";
import { LINES } from "./lines.ts";

export interface CircleRelays {
  /** The suite's circle on relays A and B, both checked. */
  world: World;
  a: string;
  b: string;
  /** An unchecked relay with the same root: accepts anything whose envelope signature verifies. */
  hostile: string;
}

export interface NodeContext extends CircleRelays {
  node: NodeRunner;
  /**
   * A circle founded on its own (docs/protocol.md, circle) on fresh relays A, B and an unchecked
   * one, its root's admins the suite's test release signers, so `world.bindAdmins` binds them.
   */
  ownCircle: () => Promise<CircleRelays>;
}

function sync(context: NodeContext, relays: string[]): Promise<NodeState> {
  return context.node.sync(context.world.host.device.signer, relays);
}

function key(state: NodeState, k: string) {
  return state.keys.find((s) => s.key === k);
}

/**
 * A member's valid note on relays A and the unchecked relay, then `bad`, made from what the member's
 * device would sign next, on the unchecked relay alone, which serves it unverified. The node reads the
 * valid note, records `bad` as an invalid_envelope fault at the author and seq it claims, and neither
 * folds nor shows it. A node that skips verification shows it as the member's next note.
 */
async function servedUnverified(context: NodeContext, name: string, bad: (next: SignedEnvelope) => SignedEnvelope): Promise<void> {
  const { world, a, hostile } = context;
  const [m] = await world.members([name], [a, hostile]);
  const device: Author = m!.device;
  const valid = await world.post(device, `${name}: valid`, [a, hostile]);
  const signed = bad(device.peek("summary", summaryBody(`${name}: as signed (${world.tag})`), await world.epoch(a)));
  const hash = envelopeHash(signed.envelope);
  await world.publish([hostile], device, signed);
  const state = await sync(context, [hostile, a]);
  check(state.feed.includes(envelopeHash(valid.envelope)), "the member's valid note is in the feed");
  check(!state.feed.includes(hash), `the envelope that does not verify (${hash}) is not in the feed`);
  equal(
    state.faults.filter((f) => f.author === device.key),
    [{ kind: "invalid_envelope", author: device.key, seq: signed.envelope.seq, hashes: [hash] }],
    "faults for the member's device",
  );
  equal(state.gaps.filter((g) => g.author === device.key), [], "gaps for the member's device");
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
      // The feed is ordered by (created_at, hash), so the order this case checks needs three distinct
      // times: two notes signed in one millisecond are ordered by their hashes.
      const start = Date.now();
      const note = async (n: number, relays: string[]) => {
        const signed = await world.summary(m!.device, `gap ${n}`, relays[0], new Date(start + n));
        await world.publish(relays, m!.device, signed);
        return signed;
      };
      const one = await note(1, [a, b]);
      const two = await note(2, [b]);
      const three = await note(3, [a, b]);
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
    id: "node.gap.none-before-join",
    covers: LINES.epoch,
    title: "Content written before a member joined leaves no gap in that member's state",
    async run(context) {
      const { world, a, b } = context;
      const [writer] = await world.members(["writes before the join"], [a, b]);
      const before = await world.post(writer!.device, "before the newcomer", [a, b]);
      const [newcomer] = await world.members(["joins after the write"], [a, b]);
      const after = await world.post(writer!.device, "after the newcomer", [a, b]);
      const state = await context.node.sync(newcomer!.device.signer, [a, b]);
      check(!state.feed.includes(envelopeHash(before.envelope)), "the newcomer's feed does not hold the note written before they joined");
      check(state.feed.includes(envelopeHash(after.envelope)), "the newcomer's feed holds the note written after they joined");
      equal(state.gaps.filter((g) => g.author === writer!.device.key), [], "gaps for the writer's device, read by the newcomer");
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
    id: "node.verify.bad-signature",
    covers: LINES.verification,
    title: "An envelope whose signature does not verify, served by a relay that skipped its check, is a fault and is not used",
    async run(context) {
      await servedUnverified(context, "bad signature", (next) => ({
        ...next,
        envelope: { ...next.envelope, created_at: isoTime(new Date(Date.parse(next.envelope.created_at) + 1000)) },
      }));
    },
  },
  {
    id: "node.verify.bad-body-hash",
    covers: LINES.verification,
    title: "An envelope served with a body that does not match its body_hash is a fault and is not used",
    async run(context) {
      await servedUnverified(context, "bad body hash", (next) => ({ envelope: next.envelope, body: summaryBody(`bad body hash: tampered (${context.world.tag})`) }));
    },
  },
  {
    id: "node.verify.forged-author",
    covers: LINES.verification,
    title: "An envelope naming an admitted member's device as author but signed by another key is a fault and is not used",
    async run(context) {
      const forger = Signer.random();
      await servedUnverified(context, "forged author", (next) => {
        const unsigned = unsignedPart(next.envelope);
        return { envelope: { ...unsigned, signature: forger.sign(jcs(unsigned)) }, ...(next.body === undefined ? {} : { body: next.body }) };
      });
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
      const choice = await world.post(world.host.device, "the choice", [a, b], "item", namedItemBody([m!.identity.key], "choice"));
      const item = envelopeHash(choice.envelope);
      const epoch = await world.epoch(a);
      const picks = [5, 3].map((seq) => signEnvelope(mail.signer, { kind: "decision", body: pickBody(item, `option ${seq}`), seq, prev: item, epoch }));
      for (const pick of picks) await world.publish([a, b], mail, pick);
      const state = await sync(context, [a, b]);
      equal(state.gaps.filter((g) => g.author === mail.key), [], "gaps for the mail key");
      equal(state.faults.filter((f) => f.author === mail.key), [], "faults for the mail key");
      for (const pick of picks) check(state.feed.includes(envelopeHash(pick.envelope)), `the feed holds the pick at seq ${pick.envelope.seq}`);
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
      "A relay that never saw a revoke serves a revoked mail key's picks the revoke does not list, one of them backdated before the revoke; the node keeps the picks mail_read lists and ignores both",
    async run(context) {
      const { world, a, b } = context;
      const [m] = await world.members(["revoked mail key"], [a, b]);
      const mail = await world.addDevice(m!, "mail", [a, b]);
      const choice = await world.post(world.host.device, "the choice", [a, b], "item", namedItemBody([m!.identity.key], "choice"));
      const item = envelopeHash(choice.envelope);
      const epoch = await world.epoch(a);
      const pick = (seq: number, option: string, createdAt?: Date) =>
        signEnvelope(mail.signer, {
          kind: "decision",
          body: pickBody(item, option),
          seq,
          prev: item,
          epoch,
          ...(createdAt === undefined ? {} : { createdAt }),
        });
      const honest = pick(7, "honest");
      await world.publish([a, b], mail, honest);
      const onlyB = pick(3, "honest, on B only");
      await world.publish([b], mail, onlyB);
      const revokedAt = new Date(Date.now() + 1000);
      const mailRead = { [mail.key]: [envelopeHash(honest.envelope), envelopeHash(onlyB.envelope)] };
      await world.publish([a], m!.device, await world.revoke(m!.device, m!.identity, mail.key, [], a, revokedAt, mailRead));
      const after = pick(9, "after the revoke", new Date(revokedAt.getTime() + 1000));
      accepted((await world.appendTo([b], mail, after))[0]!, "relay B, which never saw the revoke, accepts the later pick");
      // A seq the honest key never used and a created_at between the key's admission and the revoke:
      // a merge-order cutoff would read it, and no seq cutoff can bound a chainless key.
      const backdated = pick(1, "backdated by a thief", new Date(revokedAt.getTime() - 500));
      accepted((await world.appendTo([b], mail, backdated))[0]!, "relay B accepts the pick a thief backdated before the revoke");
      const state = await sync(context, [b, a]);
      check(key(state, mail.key)?.revoked === true, "the fold marks the mail key revoked");
      check(state.feed.includes(envelopeHash(honest.envelope)), "the pick mail_read lists stays");
      check(state.feed.includes(envelopeHash(onlyB.envelope)), "the listed pick only relay B holds stays");
      check(!state.feed.includes(envelopeHash(after.envelope)), "the pick from after the revoke is ignored");
      check(!state.feed.includes(envelopeHash(backdated.envelope)), "the unlisted pick is ignored though its created_at is before the revoke");
    },
  },
  {
    id: "node.revocation.host-device-window",
    covers: LINES.hostDeviceRevoke,
    title:
      "The dinner's device key revokes a joiner inside 7 days of the join and not after, judged by the join's and the revoke's created_at, though a relay accepted both revokes",
    async run(context) {
      const { world, a } = context;
      const [freshInvite, staleInvite] = await world.dinner(["joined today", "joined eight days ago"], [a]);
      const fresh = world.joinFor(freshInvite!);
      const stale = world.joinFor(staleInvite!, new Date(Date.now() - 8 * 24 * 3600 * 1000));
      for (const joined of [fresh, stale]) await world.publish([a], joined.member.device, joined.signed, { unsigned: true });
      const host = world.host.device;
      for (const joined of [fresh, stale]) {
        await world.publish([a], host, await world.revoke(host, host.signer, joined.member.identity.key, [joined.member.device], a));
      }
      const state = await sync(context, [a]);
      check(key(state, fresh.member.identity.key)?.revoked === true, "the identity that joined today is revoked");
      check(key(state, fresh.member.device.key)?.revoked === true, "and its device");
      check(key(state, stale.member.identity.key)?.role === "identity", "the identity that joined eight days ago is admitted");
      check(key(state, stale.member.identity.key)?.revoked !== true, "and not revoked: the revoke is past the window");
    },
  },
  {
    id: "node.revocation.admin-revokes-member",
    covers: LINES.adminRevoke,
    title:
      "In a circle whose signer set binds every key, an admin key's revoke of a member, posted by the admin's own device, revokes the member and every key under them",
    async run(context) {
      const { world, a, b } = await context.ownCircle();
      const [first, second, member, bystander] = await world.members(["admin revoke first admin", "admin revoke second admin", "admin revoke member", "admin revoke bystander"], [a, b]);
      const [firstKey] = await world.bindAdmins([first!, second!], [a, b]);
      await world.publish([a, b], first!.device, await world.revoke(first!.device, firstKey!, member!.identity.key, [member!.device], a));
      const state = await context.node.sync(world.host.device.signer, [a, b]);
      check(key(state, member!.identity.key)?.revoked === true, "the member's identity is revoked");
      check(key(state, member!.device.key)?.revoked === true, "and the member's device");
      for (const kept of [first!, second!, bystander!]) check(key(state, kept.identity.key)?.revoked === false, `${kept.name} is not revoked`);
    },
  },
  {
    id: "node.revocation.admin-may-not-revoke-admin",
    covers: LINES.adminRevoke,
    title:
      "Served by a relay that accepted them, an admin key's revoke of a sitting admin, one by a key outside the signer set, and one posted by another member's device revoke nobody",
    async run(context) {
      const { world, a, hostile } = await context.ownCircle();
      const [first, second, member, bystander] = await world.members(["sitting admin first", "sitting admin second", "unrevoked member", "unrevoking bystander"], [a, hostile]);
      const [firstKey] = await world.bindAdmins([first!, second!], [a, hostile]);
      await world.publish([hostile], first!.device, await world.revoke(first!.device, firstKey!, second!.identity.key, [second!.device], a));
      await world.publish([hostile], first!.device, await world.revoke(first!.device, Signer.random(), member!.identity.key, [member!.device], a));
      await world.publish([hostile], bystander!.device, await world.revoke(bystander!.device, firstKey!, member!.identity.key, [member!.device], a));
      const state = await context.node.sync(world.host.device.signer, [a, hostile]);
      check(key(state, second!.identity.key)?.revoked === false, "the sitting admin is not revoked");
      check(key(state, second!.device.key)?.revoked === false, "nor their device");
      check(key(state, member!.identity.key)?.revoked === false, "the member is not revoked by a key outside the set, nor from another member's device");
    },
  },
  {
    id: "node.keep.admins-only",
    covers: LINES.keep,
    title:
      "A Keep from an admin's device is honoured; one from a member who is no admin, and one the admin dated before a signer_set bound them, are ignored",
    async run(context) {
      const { world, a } = await context.ownCircle();
      const [first, second, member, bystander] = await world.members(["keeping admin", "other admin", "member in review", "keeping bystander"], [a]);
      // The node's own key, which every Keep is sealed to beside the admins and the member.
      const reader = EncryptionKey.random();
      const to = [first!, second!, member!].map((m) => m.identity.key).sort();
      const post = (author: typeof first, keep: Keep) => world.post(author!.device, "", [a], "keep", { to, sealed: seal({ member: keep.member, created_at: keep.created_at, by: keep.by, signature: keep.signature }, [reader.raw]) });
      const early = signKeep(first!.device.signer, member!.identity.key, new Date(Date.now() - 3600 * 1000));
      await world.bindAdmins([first!, second!], [a]);
      const later = new Date(Date.now() + 1000);
      const byAdmin = signKeep(first!.device.signer, member!.identity.key, later);
      const byBystander = signKeep(bystander!.device.signer, member!.identity.key, later);
      for (const [author, keep] of [[first, early], [first, byAdmin], [bystander, byBystander]] as const) await post(author, keep);
      const state = await context.node.sync(world.host.device.signer, [a], reader);
      equal(state.keeps, [keepId(byAdmin)], "the Keeps the node honours: the admin's, dated after the signer_set that seats them");
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
      // The node folds joins by (created_at, hash), so the spent join is dated strictly after the
      // valid one: two joins in the same millisecond would leave which one spends the invite to the hash.
      // The valid join is itself dated after the dinner: a join sharing the dinner's millisecond and
      // sorting ahead of it by hash is deferred, and the spent join would take the invite first.
      const validAt = new Date(Date.now() + 1000);
      const valid = world.joinFor(open!, validAt);
      await world.publish([a, hostile], valid.member.device, valid.signed, { unsigned: true });
      const spent = world.joinFor(open!, new Date(validAt.getTime() + 1000));
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
    id: "node.bootstrap.join-replicated-after-expiry",
    covers: LINES.pushedJoin,
    title: "A join relay A accepted reaches relay B after its invite expired, with the member's self-authored device message, through an admitted member's node",
    async run(context) {
      const { world, a, b } = context;
      const [invitation] = await world.dinner(["replicated guest"], [a, b], { expired: true });
      const { member, signed } = world.joinFor(invitation!, new Date(Date.now() - 2 * 3600 * 1000));
      // Relay A holds the join, judged by its created_at; the guest's own append reaches relay B too late.
      await world.publish([a], world.host.device, signed);
      equal((await world.client(b, member.device).append(signed, { unsigned: true })).status, 422, "relay B on the guest's own late join");
      const replacement = await world.selfDevice(member, member.identity, a);
      await world.publish([a], replacement.device, replacement.signed, { unsigned: true });
      equal((await world.client(b, member.device).circle()).status, 401, "the member's read of relay B before the sync");
      await sync(context, [a, b]);
      const view = (await world.client(b, world.host.device).circle()).body as { keys: Array<{ key: string; role: string }> };
      const role = (k: string) => view.keys.find((s) => s.key === k)?.role;
      equal(role(member.identity.key), "identity", "relay B on the member's identity");
      equal(role(member.device.key), "device", "relay B on the member's device");
      equal(role(replacement.device.key), "device", "relay B on the member's self-authored device");
      equal((await world.client(b, member.device).circle()).status, 200, "the member's read of relay B after the sync");
    },
  },
  {
    id: "node.device.self-authored",
    covers: LINES.lostDevice,
    title: "A self-authored device message with a valid identity signature is admitted; one with a forged signature, served by a relay that accepted it, is not",
    async run(context) {
      const { world, a, hostile } = context;
      const [m] = await world.members(["lost laptop"], [a, hostile]);
      const replacement = await world.selfDevice(m!, m!.identity, a);
      await world.publish([a, hostile], replacement.device, replacement.signed, { unsigned: true });
      const note = await world.post(replacement.device, "from the replacement laptop", [a]);
      const forged = await world.selfDevice(m!, Signer.random(), a);
      await world.publish([hostile], forged.device, forged.signed, { unsigned: true });
      const state = await sync(context, [hostile, a]);
      equal(key(state, replacement.device.key)?.role, "device", "the replacement key's role");
      equal(key(state, replacement.device.key)?.identity, m!.identity.key, "the replacement key's identity");
      check(state.feed.includes(envelopeHash(note.envelope)), "the replacement laptop's note is in the feed");
      check(key(state, forged.device.key) === undefined, "the forged key is not admitted");
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
