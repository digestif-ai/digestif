// The writer against a fake harness that answers from recorded fixtures. The real Claude Code is
// never called.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, afterEach, beforeEach, test } from "node:test";
import { buildSystemPrompt, DEFAULT_RULES, fetchContext, harnessArgs, isSignedOut, writeNote } from "../src/writer.ts";
import { assertGone } from "./processes.ts";

const here = import.meta.dirname;
const harness = join(here, "fake-harness.mjs");
const fixture = (n: string) => join(here, "harness-fixtures", n);
const bin = join(here, "..", "bin", "write.ts");
const digest = ["session: Fix the fetcher", "commit: Add a retry to the fetcher"];

let dir: string;
let log: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "digestif-writer-test-"));
  log = join(dir, "harness.log");
  process.env["FAKE_LOG"] = log;
  process.env["ANTHROPIC_API_KEY"] = "not-a-real-key";
});
afterEach(() => {
  for (const k of ["FAKE_LOG", "FAKE_FIXTURE", "FAKE_EXIT", "FAKE_SLEEP_MS", "FAKE_GRANDCHILD", "ANTHROPIC_API_KEY", "DIGESTIF_SESSION"]) delete process.env[k];
  rmSync(dir, { recursive: true, force: true });
});
after(() => rmSync(dir, { recursive: true, force: true }));
const calls = () => readFileSync(log, "utf8").trim().split("\n").map((l) => JSON.parse(l) as { argv: string[]; cwd: string; stdin: string; pid: number; grandchild?: number; apiKey: boolean; session: boolean });

test("a note comes back, from a run with no tools, a budget, an empty temp directory and no API key", async () => {
  process.env["FAKE_FIXTURE"] = fixture("note.txt");
  process.env["DIGESTIF_SESSION"] = "not-a-real-session";
  const r = await writeNote(digest, { harness, brief: "I build a fetcher.", rules: "Keep it short.", maxBudgetUsd: 0.25 });
  assert.equal(r.status, "note");
  assert.match((r as { note: string }).note, /^Worked on: .*\nLearned: .*\nStuck on: /);
  const [c] = calls();
  assert.ok(c);
  assert.deepEqual(c.argv.slice(0, 3), ["-p", "--tools", ""]);
  assert.ok(c.argv.includes("--no-session-persistence"));
  assert.ok(c.argv.includes("--strict-mcp-config"), "no MCP server adds tools back");
  assert.ok(!c.argv.includes("--mcp-config") && !c.argv.includes("--allowedTools"));
  assert.equal(c.argv[c.argv.indexOf("--max-budget-usd") + 1], "0.25");
  const system = c.argv[c.argv.indexOf("--system-prompt") + 1]!;
  assert.match(system, /Worked on:[\s\S]*Learned:[\s\S]*Stuck on:/);
  assert.ok(system.includes("I build a fetcher.") && system.includes("Keep it short.") && system.includes(DEFAULT_RULES));
  assert.ok(c.stdin.includes("commit: Add a retry to the fetcher"));
  assert.ok(!c.stdin.includes("Keep it short."), "the digest is the user message; context is the system prompt");
  assert.ok(c.cwd.includes("digestif-writer-"), "an empty temp directory");
  assert.equal(c.apiKey, false, "the harness runs under the login, not a key");
  assert.equal(c.session, false, "the node's session cookie stays out of the harness");
});

test("an empty answer is no note", async () => {
  process.env["FAKE_FIXTURE"] = fixture("empty.txt");
  assert.deepEqual(await writeNote(digest, { harness }), { status: "empty" });
});

test("the harness's sign-in failure maps to signed_out, a plain failure to failed", async () => {
  process.env["FAKE_FIXTURE"] = fixture("signed-out.txt");
  process.env["FAKE_EXIT"] = "1";
  assert.deepEqual(await writeNote(digest, { harness }), { status: "signed_out" });
  process.env["FAKE_FIXTURE"] = fixture("empty.txt");
  assert.equal((await writeNote(digest, { harness })).status, "failed");
  assert.equal((await writeNote(digest, { harness: join(dir, "missing") })).status, "failed");
  assert.equal(isSignedOut(0, "Not logged in"), false, "a note that says so is a note");
});

test("a timeout kills the child and its process group", async () => {
  process.env["FAKE_SLEEP_MS"] = "20000";
  process.env["FAKE_GRANDCHILD"] = "1";
  process.env["FAKE_FIXTURE"] = fixture("note.txt");
  const t = Date.now();
  assert.deepEqual(await writeNote(digest, { harness, timeoutMs: 400 }), { status: "timeout" });
  assert.ok(Date.now() - t < 5000);
  const { pid, grandchild } = calls()[0]!;
  await assertGone(pid, "the harness");
  assert.ok(grandchild !== undefined);
  await assertGone(grandchild, "the grandchild, which dies with the group");
});

test("the prompt fills the brief and the rules, and the conservative rules always apply", () => {
  const p = buildSystemPrompt("B={{brief}} D={{default_rules}} R={{rules}}", "", "");
  assert.equal(p, `B=(none) D=${DEFAULT_RULES} R=(none)`);
  assert.deepEqual(harnessArgs("sys", 1).slice(0, 2), ["-p", "--tools"]);
});

function cli(input: string, args: string[], env: Record<string, string> = {}) {
  return spawnSync(process.execPath, [bin, "--harness", harness, ...args], { input, encoding: "utf8", env: { ...process.env, ...env } });
}

test("bin/write.ts follows the node's DIGESTIF_WRITER contract", () => {
  const ok = cli(digest.join("\n") + "\n", [], { FAKE_FIXTURE: fixture("note.txt") });
  assert.equal(ok.status, 0);
  assert.match(ok.stdout, /^Worked on:/);
  assert.equal(cli(digest.join("\n") + "\n", [], { FAKE_FIXTURE: fixture("empty.txt") }).status, 1);
  assert.equal(cli(digest.join("\n") + "\n", [], { FAKE_FIXTURE: fixture("signed-out.txt"), FAKE_EXIT: "1" }).status, 4);
  assert.equal(cli("", [], { FAKE_FIXTURE: fixture("note.txt") }).status, 1);
  assert.equal(cli("x\n", ["--bogus"]).status, 2);
  const t = cli(digest.join("\n"), ["--timeout-seconds", "0.3"], { FAKE_FIXTURE: fixture("note.txt"), FAKE_SLEEP_MS: "20000" });
  assert.equal(t.status, 1);
});

test("--brief and --rules reach the system prompt", () => {
  writeFileSync(join(dir, "brief.txt"), "BRIEF-TEXT");
  writeFileSync(join(dir, "rules.txt"), "RULES-TEXT");
  cli("x\n", ["--brief", join(dir, "brief.txt"), "--rules", join(dir, "rules.txt")], { FAKE_FIXTURE: fixture("note.txt") });
  const system = calls()[0]!.argv.join("\n");
  assert.ok(system.includes("BRIEF-TEXT") && system.includes("RULES-TEXT"));
});

test("DIGESTIF_WRITER_TASK=brief drafts from the brief prompt, with the card and the sources as data", () => {
  const input = ["name: Ada Park", "agent: Athena", ...digest].join("\n") + "\n";
  const r = cli(input, [], { FAKE_FIXTURE: fixture("note.txt"), DIGESTIF_WRITER_TASK: "brief" });
  assert.equal(r.status, 0);
  const c = calls()[0]!;
  const system = c.argv.join("\n");
  assert.ok(system.includes("You draft a first brief") && !system.includes("nightly note"));
  assert.match(c.stdin, /^The person's card and sources, as data:\n\nname: Ada Park\nagent: Athena\n/);
  assert.equal(cli(input, [], { FAKE_FIXTURE: fixture("note.txt"), DIGESTIF_WRITER_TASK: "poem" }).status, 2);
});

test("with a node and a session, the brief and rules are read from the node's local API", async () => {
  const seen: { url?: string; cookie?: string; local?: string }[] = [];
  const server = createServer((req, res) => {
    seen.push({ url: req.url ?? "", cookie: req.headers.cookie ?? "", local: String(req.headers["digestif-local"]) });
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ text: req.url === "/api/v0/brief" ? "API-BRIEF" : "API-RULES" }));
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  try {
    const addr = server.address() as { port: number };
    const node = `http://127.0.0.1:${addr.port}`;
    assert.deepEqual(await fetchContext({ node, session: "s1" }), { brief: "API-BRIEF", rules: "API-RULES" });
    assert.deepEqual(seen[0], { url: "/api/v0/brief", cookie: "digestif_session=s1", local: "1" });
    assert.equal(seen[1]?.url, "/api/v0/rules");
    await assert.rejects(fetchContext({ node: "https://relay.example.org", session: "s1" }), /loopback/);
    assert.equal(seen.length, 2, "the cookie goes to no other host");
    writeFileSync(join(dir, "brief.txt"), "FILE-BRIEF");
    const r = await new Promise<number | null>((resolve) => {
      const c = spawn(process.execPath, [bin, "--harness", harness, "--brief", join(dir, "brief.txt")], {
        env: { ...process.env, FAKE_FIXTURE: fixture("note.txt"), DIGESTIF_NODE: node, DIGESTIF_SESSION: "s1" },
        stdio: ["pipe", "ignore", "ignore"],
      });
      c.on("close", resolve);
      c.stdin.end("x\n");
    });
    assert.equal(r, 0);
    const system = calls()[0]!.argv.join("\n");
    assert.ok(system.includes("API-BRIEF") && !system.includes("FILE-BRIEF"));
  } finally {
    server.close();
  }
});
