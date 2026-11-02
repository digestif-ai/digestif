// The writer against a fake harness that answers from recorded fixtures. The real Claude Code is
// never called.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, afterEach, beforeEach, test } from "node:test";
import { AwakeClock, holdAwake, SLEEP_GAP_MS } from "../src/awake.ts";
import { ALWAYS_ON_RULES, buildSystemPrompt, DEFAULT_RULES, fetchContext, harnessArgs, isSignedOut, resultEvent, writeNote } from "../src/writer.ts";
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
  for (const k of ["FAKE_LOG", "FAKE_FIXTURE", "FAKE_EXIT", "FAKE_SLEEP_MS", "FAKE_TRICKLE_MS", "FAKE_GRANDCHILD", "ANTHROPIC_API_KEY", "DIGESTIF_SESSION"]) delete process.env[k];
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
  assert.equal(c.argv[c.argv.indexOf("--output-format") + 1], "stream-json", "streamed, so silence means a hang");
  assert.ok(c.argv.includes("--verbose") && c.argv.includes("--include-partial-messages"));
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

test("a harness that goes quiet is hung: it and its process group are killed", async () => {
  process.env["FAKE_SLEEP_MS"] = "20000";
  process.env["FAKE_GRANDCHILD"] = "1";
  process.env["FAKE_FIXTURE"] = fixture("note.txt");
  const t = Date.now();
  assert.deepEqual(await writeNote(digest, { harness, quietMs: 400 }), { status: "hung", quietMs: 400 });
  assert.ok(Date.now() - t < 5000);
  const { pid, grandchild } = calls()[0]!;
  await assertGone(pid, "the harness");
  assert.ok(grandchild !== undefined);
  await assertGone(grandchild, "the grandchild, which dies with the group");
});

test("a run that keeps writing is not hung, however long it takes", async () => {
  process.env["FAKE_SLEEP_MS"] = "1500";
  process.env["FAKE_TRICKLE_MS"] = "100";
  process.env["FAKE_FIXTURE"] = fixture("note.txt");
  assert.equal((await writeNote(digest, { harness, quietMs: 700 })).status, "note");
});

test("a sleep in the middle of the writer is a pause, not silence", async () => {
  // The harness is quiet for 1.5 seconds of real time; the wall clock jumps an hour in the middle,
  // as it does when the lid closes. A wall-clock limit would read the hour as a hang.
  process.env["FAKE_SLEEP_MS"] = "1500";
  process.env["FAKE_FIXTURE"] = fixture("note.txt");
  const start = Date.now();
  const now = () => Date.now() + (Date.now() - start > 500 ? 3_600_000 : 0);
  assert.equal((await writeNote(digest, { harness, quietMs: 1_400, now })).status, "note");
});

test("the awake clock counts the time between readings and skips a gap as sleep", () => {
  let t = 0;
  const c = new AwakeClock(() => t);
  t = 1000;
  assert.equal(c.read(), 1000);
  t += SLEEP_GAP_MS + 1;
  assert.equal(c.read(), 1000, "a gap is a sleep");
  t += 500;
  assert.equal(c.read(), 1500);
  assert.equal(c.slept(), SLEEP_GAP_MS + 1);
});

test("the power assertion is caffeinate -i -w on macOS, waiting on this process, and nothing elsewhere", () => {
  const seen: { cmd: string; args: string[] }[] = [];
  const fake = ((cmd: string, args: string[]) => {
    seen.push({ cmd, args });
    return spawn(process.execPath, ["-e", ""], { stdio: "ignore" });
  }) as Parameters<typeof holdAwake>[1];
  assert.equal(holdAwake("linux", fake, 42), undefined);
  assert.deepEqual(seen, []);
  assert.ok(holdAwake("darwin", fake, 42));
  assert.deepEqual(seen, [{ cmd: "/usr/bin/caffeinate", args: ["-i", "-w", "42"] }]);
});

test("the stream's result event is the answer; every other line is progress", () => {
  assert.deepEqual(resultEvent('{"type":"result","subtype":"success","is_error":false,"result":"hi"}'), { isError: false, text: "hi", subtype: "success" });
  assert.deepEqual(resultEvent('{"is_error":true,"type":"result","subtype":"error_max_budget_usd"}'), { isError: true, text: "", subtype: "error_max_budget_usd" });
  assert.equal(resultEvent('{"type":"stream_event"}'), undefined);
  assert.equal(resultEvent("not json"), undefined);
});

test("the prompt fills the brief and the rules, and the conservative rules always apply", () => {
  const p = buildSystemPrompt("A={{always_on_rules}} B={{brief}} D={{default_rules}} R={{rules}}", "", "");
  assert.equal(p, `A=${ALWAYS_ON_RULES} B=(none) D=${DEFAULT_RULES} R=(none)`);
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
  const t = cli(digest.join("\n"), ["--quiet-seconds", "0.3"], { FAKE_FIXTURE: fixture("note.txt"), FAKE_SLEEP_MS: "20000" });
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
    if (req.url === "/api/v0/learnings") {
      res.statusCode = 501;
      res.end("[]");
    } else if (req.url === "/api/v0/rules/deny") {
      res.end(JSON.stringify([{ id: "d1", kind: "domain", value: "acme.example", created_at: "2026-10-29T00:00:00Z", trips: 0 }, { kind: "bogus" }]));
    } else res.end(JSON.stringify({ text: req.url === "/api/v0/brief" ? "API-BRIEF" : "API-RULES" }));
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  try {
    const addr = server.address() as { port: number };
    const node = `http://127.0.0.1:${addr.port}`;
    // Learnings the node does not serve yet read as empty; the deny list keeps only its entries.
    assert.deepEqual(await fetchContext({ node, session: "s1" }), { brief: "API-BRIEF", rules: "API-RULES", learnings: "", deny: [{ kind: "domain", value: "acme.example" }] });
    assert.deepEqual(seen[0], { url: "/api/v0/brief", cookie: "digestif_session=s1", local: "1" });
    assert.equal(seen[1]?.url, "/api/v0/rules");
    await assert.rejects(fetchContext({ node: "https://relay.example.org", session: "s1" }), /loopback/);
    assert.equal(seen.length, 4, "the cookie goes to no other host");
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
