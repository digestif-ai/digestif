// Relay cases: run over HTTP against any relay URL configured with the test circle's root.
import { answerBody, retractBody, revokeBody, summaryBody } from "../bodies.ts";
import { jcs } from "../encoding.ts";
import { envelopeHash, isCircleState, signEnvelope, verifyEnvelope, type StoredEnvelope } from "../envelope.ts";
import { accepted, check, equal, errorCodes, ok, refused, type Case } from "../harness.ts";
import { Signer } from "../keys.ts";
import { sendRaw } from "../request.ts";
import type { World } from "../world.ts";
import { LINES } from "./lines.ts";

interface CircleView {
  root: string;
  epoch: number;
  keys: Array<{ key: string; role: string; identity: string; join_epoch: number; revoked_at?: number | null; after_seq?: number | null }>;
  limits: { max_envelope_bytes: number; max_appends_per_device_per_day: number; max_page_size: number; skew_seconds: number };
}

async function circleOf(world: World, url: string = world.relay(0)): Promise<CircleView> {
  const result = await world.client(url, world.host.device).circle();
  ok(result, `GET /v0/circle on ${url}`);
  return result.body as CircleView;
}

function keyOf(view: CircleView, key: string) {
  return view.keys.find((k) => k.key === key);
}

function isRevoked(view: CircleView, key: string): boolean {
  const state = keyOf(view, key);
  return state?.revoked_at !== undefined && state?.revoked_at !== null;
}

async function hashes(world: World, url: string): Promise<Map<string, StoredEnvelope>> {
  const all = await world.client(url, world.host.device).fetchAll();
  return new Map(all.map((s) => [s.hash, s]));
}

const NOT_ADMITTED = [401, 422];

export const relayCases: Case<World>[] = [
  {
    id: "relay.circle.root",
    covers: LINES.bootstrap,
    title: "The relay is configured with the test circle's root and reports its limits",
    async run(world) {
      for (const url of world.urls) {
        const view = await circleOf(world, url);
        equal(view.root, world.circle.rootHash, `${url} root`);
        for (const limit of ["max_envelope_bytes", "max_appends_per_device_per_day", "max_page_size", "skew_seconds"] as const) {
          check(Number.isInteger(view.limits?.[limit]), `${url} reports limits.${limit}`);
        }
        check(keyOf(view, world.host.device.key)?.role === "device", `${url} admits the root dinner's authoring device key`);
        check(keyOf(view, world.host.identity.key)?.role === "identity", `${url} admits the root dinner's host identity`);
      }
    },
  },
  {
    id: "relay.divergent.same-fold",
    covers: LINES.divergent,
    title: "Two relays receiving the same joins in opposite orders fold to the same admitted set",
    relays: 2,
    async run(world) {
      const [a, b] = [world.relay(0), world.relay(1)];
      const before = [await world.epoch(a), await world.epoch(b)];
      const invitations = await world.dinner(["divergent x", "divergent y"], [a, b]);
      const [x, y] = invitations.map((i) => world.joinFor(i));
      if (x === undefined || y === undefined) throw new Error("two invitations expected");
      for (const signed of [x.signed, y.signed]) accepted((await world.appendTo([a], x.member.device, signed, { unsigned: true }))[0]!, "join on relay A");
      for (const signed of [y.signed, x.signed]) accepted((await world.appendTo([b], x.member.device, signed, { unsigned: true }))[0]!, "join on relay B");
      const note = await world.post(x.member.device, "divergent note", [b, a]);
      const views = [await circleOf(world, a), await circleOf(world, b)];
      equal(views[0]!.epoch - before[0]!, 2, "relay A epoch advance");
      equal(views[1]!.epoch - before[1]!, 2, "relay B epoch advance");
      const ours = [x.member.identity.key, x.member.device.key, y.member.identity.key, y.member.device.key];
      const project = (view: CircleView) =>
        ours.map((k) => {
          const state = keyOf(view, k);
          return state === undefined ? null : { key: k, role: state.role, identity: state.identity, revoked: isRevoked(view, k) };
        });
      equal(project(views[0]!), project(views[1]!), "admitted keys on A and B");
      check(project(views[0]!).every((k) => k !== null), "both relays admit both members");
      const held = [await hashes(world, a), await hashes(world, b)];
      for (const hash of [x.member.joinHash, y.member.joinHash, envelopeHash(note.envelope)]) {
        check(held.every((h) => h.has(hash)), `both relays serve ${hash}`);
      }
    },
  },
  {
    id: "relay.gap.missing-range-accepted",
    covers: LINES.gap,
    title: "A relay that missed part of a chain accepts the author's later seq, so the node can backfill elsewhere",
    async run(world) {
      const [m] = await world.members(["gap"], [world.relay(0)]);
      const device = m!.device;
      accepted((await world.appendTo([world.relay(0)], device, await world.summary(device, "gap 1")))[0]!, "seq 1");
      await world.summary(device, "gap 2, never sent here");
      accepted((await world.appendTo([world.relay(0)], device, await world.summary(device, "gap 3")))[0]!, "seq 3 after a missing seq 2");
    },
  },
  {
    id: "relay.duplicate.idempotent",
    covers: LINES.duplicate,
    title: "Appending the same envelope twice answers 200 duplicate with the same relay_id and hash",
    async run(world) {
      const [m] = await world.members(["duplicate"], [world.relay(0)]);
      const signed = await world.summary(m!.device, "duplicate");
      const client = world.client(world.relay(0), m!.device);
      const first = await client.append(signed);
      accepted(first, "first append");
      const second = await client.append(signed);
      ok(second, "second append");
      const [r1, r2] = [first.body as { relay_id: number; hash: string }, second.body as { status: string; relay_id: number; hash: string }];
      equal(r2.status, "duplicate", "second append status");
      equal(r2.relay_id, r1.relay_id, "relay_id of the duplicate");
      equal(r2.hash, envelopeHash(signed.envelope), "hash of the duplicate");
    },
  },
  {
    id: "relay.fork.refused",
    covers: LINES.duplicate,
    title: "A second, different envelope at an author's held seq is refused as a fork and the first is kept",
    async run(world) {
      const [m] = await world.members(["fork"], [world.relay(0)]);
      const device = m!.device;
      const epoch = await world.epoch();
      const first = device.peek("summary", summaryBody(`fork first (${world.tag})`), epoch);
      const second = device.peek("summary", summaryBody(`fork second (${world.tag})`), epoch);
      const client = world.client(world.relay(0), device);
      accepted(await client.append(first), "first envelope at seq 1");
      refused(await client.append(second), [422], "fork", "second envelope at seq 1");
      const held = await hashes(world, world.relay(0));
      check(held.has(envelopeHash(first.envelope)), "the relay keeps the first envelope");
      check(!held.has(envelopeHash(second.envelope)), "the relay does not store the fork");
    },
  },
  {
    id: "relay.seq.chained-regression-refused",
    covers: LINES.sequence,
    title: "A chained key's envelope at a seq below the last held is refused",
    async run(world) {
      const [m] = await world.members(["regression"], [world.relay(0)]);
      const device = m!.device;
      const client = world.client(world.relay(0), device);
      accepted(await client.append(await world.summary(device, "regression 1")), "seq 1");
      const two = await world.summary(device, "regression 2");
      accepted(await client.append(await world.summary(device, "regression 3")), "seq 3");
      refused(await client.append(two), [422], "sequence_regression", "seq 2 after seq 3");
    },
  },
  {
    id: "relay.seq.mail-regression-allowed",
    covers: LINES.sequence,
    title: "A mail key may append any seq it has not used, lower ones included",
    async run(world) {
      const [m] = await world.members(["mail"], [world.relay(0)]);
      const mail = await world.addDevice(m!, "mail", [world.relay(0)]);
      const ask = await world.post(world.host.device, "the ask", [world.relay(0)], "question", answerBody("ask"));
      const askHash = envelopeHash(ask.envelope);
      const client = world.client(world.relay(0), mail);
      const epoch = await world.epoch();
      for (const seq of [5, 3, 4]) {
        const answer = signEnvelope(mail.signer, { kind: "answer", body: answerBody(`option ${seq}`), seq, prev: askHash, epoch });
        accepted(await client.append(answer), `mail key answer at seq ${seq}`);
      }
    },
  },
  {
    id: "relay.revocation.device-refused",
    covers: LINES.revocation,
    title: "After its identity revokes a device key, that key's appends are refused and the member's other device still writes",
    async run(world) {
      const url = world.relay(0);
      const [m] = await world.members(["revoked device"], [url]);
      const lost = m!.device;
      const replacement = await world.addDevice(m!, "device", [url]);
      await world.post(lost, "before revoke", [url]);
      const cutoff = lost.seq;
      accepted(await world.client(url, replacement).append(await world.revoke(replacement, m!.identity, lost.key, [lost])), "revoke by the identity");
      refused(await world.client(url, lost).append(await world.summary(lost, "after revoke")), NOT_ADMITTED, "not_admitted", "append by the revoked device");
      const view = await circleOf(world, url);
      check(isRevoked(view, lost.key), "GET /v0/circle reports the device revoked");
      equal(keyOf(view, lost.key)?.after_seq, cutoff, "GET /v0/circle reports the revoke's cutoff for the device");
      accepted(await world.client(url, replacement).append(await world.summary(replacement, "still here")), "append by the replacement device");
    },
  },
  {
    id: "relay.revocation.identity-refused",
    covers: LINES.revocation,
    title: "After the admitting host revokes an identity, every key under it is refused",
    async run(world) {
      const url = world.relay(0);
      const [m] = await world.members(["revoked identity"], [url]);
      const mail = await world.addDevice(m!, "mail", [url]);
      accepted(await world.client(url, world.host.device).append(await world.revoke(world.host.device, world.host.identity, m!.identity.key, [m!.device])), "revoke by the host");
      refused(await world.client(url, m!.device).append(await world.summary(m!.device, "after revoke")), NOT_ADMITTED, "not_admitted", "append by the revoked identity's device");
      const view = await circleOf(world, url);
      for (const key of [m!.identity.key, m!.device.key, mail.key]) check(isRevoked(view, key), `GET /v0/circle reports ${key} revoked`);
    },
  },
  {
    id: "relay.revocation.cutoff-required",
    covers: LINES.revocation,
    title: "A revoke whose after_seq names a key it does not stop, or that carries no after_seq, is refused as malformed",
    async run(world) {
      const url = world.relay(0);
      const [m, other] = await world.members(["cutoff owner", "cutoff bystander"], [url]);
      const lost = m!.device;
      const replacement = await world.addDevice(m!, "device", [url]);
      const client = world.client(url, replacement);
      const epoch = await world.epoch(url);
      const target = lost.key;
      const by = m!.identity;
      const foreign = replacement.peek("revoke", revokeBody(by, target, { [lost.key]: lost.seq, [other!.device.key]: other!.device.seq }), epoch);
      refused(await client.append(foreign), [422], "malformed", "a revoke whose after_seq names another member's device");
      const bare = replacement.peek("revoke", { target, by: by.key, signature: by.sign(jcs({ target, by: by.key })) }, epoch);
      refused(await client.append(bare), [422], "malformed", "a revoke with no after_seq");
    },
  },
  {
    id: "relay.clock.skew-inside-window",
    covers: LINES.clock,
    title: "A request whose timestamp is inside the skew window, either side, is served",
    async run(world) {
      const skew = (await circleOf(world)).limits.skew_seconds;
      const client = world.client(world.relay(0), world.host.device);
      for (const offset of [-(skew - 120), skew - 120]) {
        ok(await client.circle({ timestamp: new Date(Date.now() + offset * 1000) }), `GET /v0/circle skewed ${offset}s`);
      }
    },
  },
  {
    id: "relay.clock.skew-outside-window",
    covers: LINES.clock,
    title: "A request whose timestamp is outside the skew window, either side, is refused as stale",
    async run(world) {
      const skew = (await circleOf(world)).limits.skew_seconds;
      const client = world.client(world.relay(0), world.host.device);
      for (const offset of [-(skew + 120), skew + 120]) {
        refused(await client.circle({ timestamp: new Date(Date.now() + offset * 1000) }), [401], "stale_request", `GET /v0/circle skewed ${offset}s`);
      }
    },
  },
  {
    id: "relay.clock.replayed-nonce",
    covers: LINES.clock,
    title: "A captured request sent again, or a new request reusing its nonce, is refused",
    async run(world) {
      const client = world.client(world.relay(0), world.host.device);
      const first = await client.circle();
      ok(first, "the original request");
      refused(await sendRaw(first.request), [401], "replayed_nonce", "the same request replayed byte for byte");
      const nonce = first.request.headers["Digestif-Nonce"];
      refused(await client.page(0, 1, { ...(nonce === undefined ? {} : { nonce }) }), [401], "replayed_nonce", "a different request reusing the nonce");
    },
  },
  {
    id: "relay.bootstrap.valid-join",
    covers: LINES.bootstrap,
    title: "A join signed by a recorded, unspent, unexpired invite key is accepted and increments the epoch",
    async run(world) {
      const url = world.relay(0);
      const before = await world.epoch(url);
      const [invitation] = await world.dinner(["valid join"], [url]);
      const { member, signed } = world.joinFor(invitation!);
      accepted(await world.client(url, member.device).append(signed, { unsigned: true }), "the join");
      const view = await circleOf(world, url);
      equal(view.epoch, before + 1, "epoch after the join");
      equal(keyOf(view, member.identity.key)?.role, "identity", "the joiner's identity role");
      equal(keyOf(view, member.device.key)?.role, "device", "the joiner's device role");
      equal(keyOf(view, member.device.key)?.join_epoch, before + 1, "the joiner's join_epoch");
    },
  },
  {
    id: "relay.bootstrap.unknown-invite-refused",
    covers: LINES.bootstrap,
    title: "A join signed by an invite key no dinner recorded is refused",
    async run(world) {
      const url = world.relay(0);
      const [real] = await world.dinner(["a real guest"], [url]);
      const { member, signed } = world.joinFor({ name: "stranger", invite: Signer.random(), dinnerHash: real!.dinnerHash });
      refused(await world.client(url, member.device).append(signed, { unsigned: true }), NOT_ADMITTED, "not_admitted", "join from an unknown invite key");
      check(keyOf(await circleOf(world, url), member.identity.key) === undefined, "the stranger is not admitted");
    },
  },
  {
    id: "relay.bootstrap.spent-invite-refused",
    covers: LINES.bootstrap,
    title: "A second join with an invite key already spent is refused",
    async run(world) {
      const url = world.relay(0);
      const [invitation] = await world.dinner(["spent invite"], [url]);
      const first = world.joinFor(invitation!);
      accepted(await world.client(url, first.member.device).append(first.signed, { unsigned: true }), "the first join");
      const second = world.joinFor(invitation!);
      refused(await world.client(url, second.member.device).append(second.signed, { unsigned: true }), NOT_ADMITTED, ["not_admitted", "fork"], "the second join on the spent invite");
      check(keyOf(await circleOf(world, url), second.member.identity.key) === undefined, "the second joiner is not admitted");
    },
  },
  {
    id: "relay.bootstrap.expired-invite-refused",
    covers: LINES.bootstrap,
    title: "A join after its invite's expires_at is refused",
    async run(world) {
      const url = world.relay(0);
      const [invitation] = await world.dinner(["expired invite"], [url], { expired: true });
      const { member, signed } = world.joinFor(invitation!);
      refused(await world.client(url, member.device).append(signed, { unsigned: true }), NOT_ADMITTED, "not_admitted", "join on an expired invite");
      check(keyOf(await circleOf(world, url), member.identity.key) === undefined, "the late joiner is not admitted");
    },
  },
  {
    id: "relay.bootstrap-read.open-invite",
    covers: LINES.bootstrapRead,
    title: "An invite key reads the dinner that lists it, body included, signed by itself",
    async run(world) {
      const url = world.relay(0);
      const [invitation] = await world.dinner(["bootstrap reader"], [url]);
      const result = await world.client(url, invitation!.invite).invite(invitation!.invite.key);
      ok(result, "GET /v0/invites/:invite_key");
      const stored = result.body as StoredEnvelope;
      equal(stored.hash, invitation!.dinnerHash, "the dinner's hash");
      equal(envelopeHash(stored.envelope), invitation!.dinnerHash, "the served envelope's own hash");
      check(verifyEnvelope(stored.envelope), "the served dinner verifies");
      const guests = (stored.body as { guests?: Array<{ invite_key: string }> } | undefined)?.guests ?? [];
      check(guests.some((g) => g.invite_key === invitation!.invite.key), "the served body lists the invite key");
    },
  },
  {
    id: "relay.bootstrap-read.closed-invites-unanswered",
    covers: LINES.bootstrapRead,
    title: "An unknown, spent or expired invite key reads 404, and any other signer reads 401",
    async run(world) {
      const url = world.relay(0);
      const stranger = Signer.random();
      equal((await world.client(url, stranger).invite(stranger.key)).status, 404, "an unknown invite key");
      const [spent] = await world.dinner(["spent reader"], [url]);
      const join = world.joinFor(spent!);
      accepted(await world.client(url, join.member.device).append(join.signed, { unsigned: true }), "the join that spends the invite");
      equal((await world.client(url, spent!.invite).invite(spent!.invite.key)).status, 404, "a spent invite key");
      const [expired] = await world.dinner(["expired reader"], [url], { expired: true });
      equal((await world.client(url, expired!.invite).invite(expired!.invite.key)).status, 404, "an expired invite key");
      const [open] = await world.dinner(["open invite, wrong signer"], [url]);
      equal((await world.client(url, world.host.device).invite(open!.invite.key)).status, 401, "an open invite read by another key");
    },
  },
  {
    id: "relay.epoch.newcomer-reads-from-join",
    covers: LINES.epoch,
    title: "A newcomer fetches every circle-state envelope and no content from before their join epoch",
    async run(world) {
      const url = world.relay(0);
      const old = await world.post(world.host.device, "before the newcomer", [url]);
      const [newcomer] = await world.members(["newcomer"], [url]);
      const fresh = await world.post(world.host.device, "after the newcomer", [url]);
      const joinEpoch = keyOf(await circleOf(world, url), newcomer!.device.key)?.join_epoch;
      check(joinEpoch !== undefined, "the newcomer has a join_epoch");
      const theirs = await world.client(url, newcomer!.device).fetchAll();
      const seen = new Set(theirs.map((s) => s.hash));
      for (const stored of (await hashes(world, url)).values()) {
        if (isCircleState(stored.envelope.kind)) check(seen.has(stored.hash), `the newcomer fetches circle-state ${stored.envelope.kind} ${stored.hash}`);
      }
      for (const stored of theirs) {
        if (!isCircleState(stored.envelope.kind)) {
          check(stored.envelope.epoch >= joinEpoch, `the newcomer is served ${stored.envelope.kind} ${stored.hash} from epoch ${stored.envelope.epoch}, before their join epoch ${joinEpoch}`);
        }
      }
      check(!seen.has(envelopeHash(old.envelope)), "the newcomer is not served the note written before they joined");
      check(seen.has(envelopeHash(fresh.envelope)), "the newcomer is served the note written after they joined");
    },
  },
  {
    id: "relay.retract.author-retracts",
    covers: LINES.retract,
    title: "A retract from the author's identity (another of their devices) drops the target's body and the envelope still verifies",
    async run(world) {
      const url = world.relay(0);
      const [m] = await world.members(["retracting author"], [url]);
      const second = await world.addDevice(m!, "device", [url]);
      const note = await world.post(m!.device, "to be retracted", [url]);
      const target = envelopeHash(note.envelope);
      accepted(await world.client(url, second).append(second.next("retract", retractBody(target), await world.epoch(url))), "the retract");
      const stored = (await hashes(world, url)).get(target);
      check(stored !== undefined, "the relay still serves the retracted envelope");
      check(stored.body === undefined || stored.body === null, "the retracted body is dropped");
      check(verifyEnvelope(stored.envelope), "the tombstone envelope still verifies");
      equal(envelopeHash(stored.envelope), target, "the tombstone's hash");
    },
  },
  {
    id: "relay.retract.other-identity-refused",
    covers: LINES.retract,
    title: "A retract naming another identity's envelope is refused and the target keeps its body",
    async run(world) {
      const url = world.relay(0);
      const [author, other] = await world.members(["retract target author", "retract interloper"], [url]);
      const note = await world.post(author!.device, "not yours to retract", [url]);
      const target = envelopeHash(note.envelope);
      const retract = other!.device.next("retract", retractBody(target), await world.epoch(url));
      refused(await world.client(url, other!.device).append(retract), [422], "retract_not_author", "retract by another identity");
      const stored = (await hashes(world, url)).get(target);
      check(stored?.body !== undefined && stored.body !== null, "the target keeps its body");
    },
  },
  {
    id: "relay.limits.oversized-refused",
    covers: LINES.limits,
    title: "An append over max_envelope_bytes is refused as too_large; one well under it is accepted",
    async run(world) {
      const url = world.relay(0);
      const max = (await circleOf(world, url)).limits.max_envelope_bytes;
      const [m] = await world.members(["oversized"], [url]);
      const client = world.client(url, m!.device);
      const epoch = await world.epoch(url);
      const big = m!.device.peek("summary", summaryBody(`oversized (${world.tag})`, "x".repeat(max + 1)), epoch);
      check(Buffer.byteLength(jcs(big)) > max, "the oversized append exceeds the cap");
      refused(await client.append(big), [413, 422], "too_large", "the oversized append");
      const fits = m!.device.next("summary", summaryBody(`fits (${world.tag})`, "x".repeat(Math.floor(max / 2))), epoch);
      accepted(await client.append(fits), "an append at half the cap");
    },
  },
  {
    id: "relay.limits.daily-append-cap",
    covers: LINES.limits,
    title: "A device's appends past max_appends_per_device_per_day in one UTC day are refused as rate_limited",
    async run(world) {
      const url = world.relay(0);
      const cap = (await circleOf(world, url)).limits.max_appends_per_device_per_day;
      const [m] = await world.members(["daily cap"], [url]);
      const client = world.client(url, m!.device);
      const epoch = await world.epoch(url);
      for (let n = 1; n <= cap; n++) {
        const result = await client.append(m!.device.next("summary", summaryBody(`cap ${n} (${world.tag})`), epoch));
        if (result.status !== 201) {
          throw new Error(`append ${n} of ${cap} answered ${result.status} ${errorCodes(result).join(",")}; the cap is ${cap}`);
        }
      }
      refused(await client.append(m!.device.next("summary", summaryBody(`cap over (${world.tag})`), epoch)), [429], "rate_limited", `append ${cap + 1}`);
    },
  },
];
