// The suite's own tests: every case passes against the fake relay and the reference node, and every
// case FAILS against a fake relay or reference node that skips the rule the case is about. The
// second half is what makes a pass against Roman's Worker or the OCaml node worth something.
import { test } from "node:test";
import assert from "node:assert/strict";
import { TestCircle } from "../src/circle.ts";
import { FakeRelay, type RelayBreak } from "../src/fake-relay.ts";
import type { Outcome } from "../src/harness.ts";
import { REFERENCE_NODE } from "../src/node-runner.ts";
import type { NodeBreak } from "../src/reference-node.ts";
import { runNodeSuite, runRelaySuite } from "../src/suites.ts";
import { nodeCases } from "../src/cases/node.ts";
import { relayCases } from "../src/cases/relay.ts";

const quiet = { log: () => {} };

async function relaySuite(breaks: RelayBreak[], only?: string[], relays = 2): Promise<Outcome[]> {
  const circle = new TestCircle(TestCircle.create("self-test", []));
  const fakes = Array.from({ length: relays }, () => new FakeRelay({ root: circle.rootHash, breaks }));
  const urls = await Promise.all(fakes.map((f) => f.listen()));
  try {
    return await runRelaySuite(circle, urls, { ...quiet, ...(only ? { only } : {}) });
  } finally {
    await Promise.all(fakes.map((f) => f.close()));
  }
}

function failed(outcomes: Outcome[]): string[] {
  return outcomes.filter((o) => o.result === "fail").map((o) => `${o.id}: ${o.message}`);
}

test("every relay case passes against the fake relay", async () => {
  const outcomes = await relaySuite([]);
  assert.deepEqual(failed(outcomes), []);
  assert.equal(outcomes.filter((o) => o.result === "pass").length, relayCases.length);
});

test("the suite is rerunnable against a relay that already holds an earlier run", async () => {
  const circle = new TestCircle(TestCircle.create("rerun", []));
  const fake = new FakeRelay({ root: circle.rootHash });
  const url = await fake.listen();
  try {
    const only = ["relay.duplicate", "relay.bootstrap", "relay.epoch", "relay.retract"];
    assert.deepEqual(failed(await runRelaySuite(circle, [url], { ...quiet, only })), []);
    assert.deepEqual(failed(await runRelaySuite(circle, [url], { ...quiet, only })), []);
  } finally {
    await fake.close();
  }
});

test("two-relay cases skip, not fail, with one relay", async () => {
  const outcomes = await relaySuite([], ["relay.divergent"], 1);
  assert.deepEqual(outcomes.map((o) => o.result), ["skip"]);
});

test("every node case passes against the reference node", async () => {
  const outcomes = await runNodeSuite(REFERENCE_NODE, quiet);
  assert.deepEqual(failed(outcomes), []);
  assert.equal(outcomes.filter((o) => o.result === "pass").length, nodeCases.length);
});

const relayBreaks: Array<[RelayBreak, string]> = [
  ["duplicate", "relay.duplicate.idempotent"],
  ["fork", "relay.fork.refused"],
  ["sequence", "relay.seq.chained-regression-refused"],
  ["mail-sequence", "relay.seq.mail-regression-allowed"],
  ["revocation", "relay.revocation.device-refused"],
  ["revocation", "relay.revocation.identity-refused"],
  ["cutoff-shape", "relay.revocation.cutoff-required"],
  ["skew", "relay.clock.skew-outside-window"],
  ["nonce", "relay.clock.replayed-nonce"],
  ["spent", "relay.bootstrap.spent-invite-refused"],
  ["expiry", "relay.bootstrap.expired-invite-refused"],
  ["self-device", "relay.device.self-authored-accepted"],
  ["device-signature", "relay.device.self-authored-bad-signature-refused"],
  ["expiry", "relay.bootstrap-read.closed-invites-unanswered"],
  ["invite-signer", "relay.bootstrap-read.closed-invites-unanswered"],
  ["epoch", "relay.epoch.newcomer-reads-from-join"],
  ["retract-drop", "relay.retract.author-retracts"],
  ["retract-author", "relay.retract.other-identity-refused"],
  ["size", "relay.limits.oversized-refused"],
  ["rate", "relay.limits.daily-append-cap"],
];

for (const [rule, id] of relayBreaks) {
  test(`${id} fails against a relay that skips ${rule}`, async () => {
    const outcomes = await relaySuite([rule], [id]);
    assert.deepEqual(outcomes.map((o) => [o.id, o.result]), [[id, "fail"]]);
  });
}

const nodeBreaks: Array<[NodeBreak, string]> = [
  ["relay-order", "node.divergent.same-fold-and-feed"],
  ["backfill", "node.gap.backfilled-from-other-relay"],
  ["gap", "node.gap.reported-when-unfilled"],
  ["dedupe", "node.duplicate.deduped"],
  ["fork", "node.fork.surfaced"],
  ["mail", "node.seq.mail-gaps-allowed"],
  ["revocation", "node.revocation.ignored-from-revoke-forward"],
  ["cutoff", "node.revocation.ignored-from-revoke-forward"],
  ["revocation", "node.revocation.mail-read-by-listed-hashes"],
  ["cutoff", "node.revocation.mail-read-by-listed-hashes"],
  ["mail-cutoff", "node.revocation.mail-read-by-listed-hashes"],
  ["bootstrap", "node.bootstrap.bad-joins-not-admitted"],
  ["self-device", "node.device.self-authored"],
  ["device-signature", "node.device.self-authored"],
  ["retract-author", "node.retract.author-only"],
];

for (const [rule, id] of nodeBreaks) {
  test(`${id} fails against a node that gets ${rule} wrong`, async () => {
    const outcomes = await runNodeSuite(`${REFERENCE_NODE} --break ${rule}`, { ...quiet, only: [id] });
    assert.deepEqual(outcomes.map((o) => [o.id, o.result]), [[id, "fail"]]);
  });
}

test("every case has a break that fails it, or is a positive control", () => {
  const broken = new Set([...relayBreaks.map(([, id]) => id), ...nodeBreaks.map(([, id]) => id)]);
  const controls = new Set(["relay.circle.root", "relay.divergent.same-fold", "relay.gap.missing-range-accepted", "relay.clock.skew-inside-window", "relay.bootstrap.valid-join", "relay.bootstrap.unknown-invite-refused", "relay.bootstrap-read.open-invite"]);
  const uncovered = [...relayCases, ...nodeCases].map((c) => c.id).filter((id) => !broken.has(id) && !controls.has(id));
  assert.deepEqual(uncovered, []);
});
