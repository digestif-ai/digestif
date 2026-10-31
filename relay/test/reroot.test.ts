// Re-rooting a database (README "Re-root"): the verdict scripts/deploy.sh acts on, and its two
// statements run against the test D1 with the Worker answering before and after.
import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import worker from "../src/index.ts";
import { CIRCLE_QUERY, clearStatement, verdict } from "../scripts/reroot.ts";

const conformanceRoot = env.CIRCLE_ROOT;
const realRoot = `sha256:${"7".repeat(64)}`;

// What `wrangler d1 execute --json --command CIRCLE_QUERY` prints for the test database.
async function wranglerOutput(): Promise<string> {
  const { results } = await env.DB.prepare(CIRCLE_QUERY).all();
  return JSON.stringify([{ results, success: true, meta: { duration: 1 } }], null, 2);
}

const getCircle = (root: string) => worker.fetch(new Request("http://relay.test/v0/circle"), { ...env, CIRCLE_ROOT: root });

describe("re-rooting a database", () => {
  beforeEach(async () => {
    await env.DB.batch([env.DB.prepare("DELETE FROM circle"), env.DB.prepare("DELETE FROM envelopes")]);
  });

  it("finds a database no request has reached fresh, and one rooted in the configured root the same", async () => {
    expect(verdict(await wranglerOutput(), realRoot)).toEqual({ kind: "fresh" });
    await getCircle(realRoot);
    expect(verdict(await wranglerOutput(), realRoot)).toEqual({ kind: "same" });
  });

  it("clears a row an unsigned request wrote under the conformance root, and the Worker then serves the new root", async () => {
    expect((await getCircle(conformanceRoot)).status).toBe(401);
    expect((await getCircle(realRoot)).status).toBe(500);
    const v = verdict(await wranglerOutput(), realRoot);
    expect(v).toEqual({ kind: "clear", root: conformanceRoot });
    await env.DB.prepare(clearStatement(conformanceRoot)).run();
    expect(verdict(await wranglerOutput(), realRoot)).toEqual({ kind: "fresh" });
    expect((await getCircle(realRoot)).status).toBe(401);
    expect(verdict(await wranglerOutput(), realRoot)).toEqual({ kind: "same" });
  });

  it("refuses a database that holds another circle's log, and the clearing statement leaves it alone", async () => {
    await getCircle(conformanceRoot);
    await env.DB.prepare(
      "INSERT INTO envelopes (hash, author, seq, kind, epoch, created_at, received_at, envelope) VALUES ('sha256:x', 'ed25519:a', 1, 'dinner', 0, 't', 't', '{}')",
    ).run();
    expect(verdict(await wranglerOutput(), realRoot)).toEqual({ kind: "refuse", root: conformanceRoot, envelopes: 1 });
    await env.DB.prepare(clearStatement(conformanceRoot)).run();
    expect(verdict(await wranglerOutput(), conformanceRoot)).toEqual({ kind: "same" });
  });

  it("leaves a row that no longer names the old root, and takes only a root hash into its statement", async () => {
    await getCircle(realRoot);
    await env.DB.prepare(clearStatement(conformanceRoot)).run();
    expect(verdict(await wranglerOutput(), realRoot)).toEqual({ kind: "same" });
    expect(() => clearStatement("sha256:' OR 1=1 --")).toThrow(/not a root hash/);
  });

  it("reads past anything wrangler prints before its JSON, and fails loud on output with none", () => {
    expect(verdict(`banner\n[{"results":[{"root":null,"envelopes":0}]}]`, realRoot)).toEqual({ kind: "fresh" });
    expect(() => verdict("✘ [ERROR] no such table: circle", realRoot)).toThrow(/no JSON/);
  });
});
