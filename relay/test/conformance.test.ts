// The conformance suite's relay cases, run in-process against the Worker through SELF, with the
// fold invariant checked after every accepted append: the admitted keys, the epoch and the invites
// in D1 must equal a full refold of the log. This is the "admitted_keys equals a refold" test of
// the D1.3 story, at the finest grain the suite allows.
import { env, SELF } from "cloudflare:test";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { relayCases } from "../../conformance/src/cases/relay.ts";
import { type SignedEnvelope } from "../../conformance/src/envelope.ts";
import { runCases } from "../../conformance/src/harness.ts";
import { Signer } from "../../conformance/src/keys.ts";
import { World } from "../../conformance/src/world.ts";
import circleFile from "../../conformance/fixtures/test-circle.json";
import { circleEpoch, foldLog, keyJson, loadKeys } from "../src/db.ts";

const RELAY = "http://relay.test";

/** Compares the derived state in D1 with a full refold of the log; throws naming the first difference. */
async function checkRefold(): Promise<void> {
  const fold = await foldLog(env.DB, env.CIRCLE_ROOT, { all: true });
  const stored = (await loadKeys(env.DB)).map(keyJson);
  const refolded = fold.admittedKeys().map(keyJson);
  expect(stored, "admitted_keys against a full refold").toEqual(refolded);
  expect(await circleEpoch(env.DB), "the circle epoch against a full refold").toBe(fold.epoch);
  const now = new Date();
  const { results } = await env.DB.prepare("SELECT key, dinner, expires_at, spent FROM invites").all<{ key: string; dinner: string; expires_at: string; spent: number }>();
  for (const row of results) {
    const open = row.spent === 0 && Date.parse(row.expires_at) > now.getTime() ? row.dinner : undefined;
    expect(fold.openInvite(row.key, now), `invite ${row.key} against the refold`).toBe(open);
  }
}

let appends = 0;
let accepted = 0;
const realFetch = globalThis.fetch;

beforeAll(() => {
  // The suite speaks HTTP to a URL; route it to the Worker under test, and refold after every append.
  globalThis.fetch = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    if (!url.startsWith(RELAY)) return realFetch(input, init);
    const response = await SELF.fetch(url, init);
    if (init?.method === "POST" && new URL(url).pathname === "/v0/envelopes") {
      appends += 1;
      if (response.status === 201) {
        accepted += 1;
        await checkRefold();
      }
    }
    return response;
  };
});

afterAll(() => {
  globalThis.fetch = realFetch;
});

describe("the conformance suite's relay cases against the Worker", () => {
  it("passes every single-relay case, the fold invariant holding after each append", async () => {
    // What TestCircle.load reads from the fixture, without node:fs: the suite's types are structural.
    const circle = {
      hostIdentity: Signer.fromSeed(circleFile.host_identity_seed),
      hostDevice: Signer.fromSeed(circleFile.host_device_seed),
      root: circleFile.root as SignedEnvelope,
      rootHash: circleFile.root_hash,
    };
    const world = new World(circle, [RELAY]);
    await world.setup();
    const lines: string[] = [];
    const outcomes = await runCases({ cases: relayCases, relayCount: 1, context: () => Promise.resolve({ value: world }), log: (line) => lines.push(line) });
    const failed = outcomes.filter((o) => o.result === "fail");
    expect(failed.map((o) => `${o.id}: ${o.message ?? ""}`), lines.join("\n")).toEqual([]);
    const skipped = outcomes.filter((o) => o.result === "skip").map((o) => o.id);
    expect(skipped).toEqual(["relay.divergent.same-fold"]);
    expect(outcomes.filter((o) => o.result === "pass").length).toBe(relayCases.length - 1);
    expect(accepted).toBeGreaterThan(500);
    expect(appends).toBeGreaterThan(accepted);
  });
});
