// Hook mode: the nightly run as the node's behavior, driven by a fake handoff on stdin against a
// fake `digestif` and the fake harness.
import assert from "node:assert/strict";
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";
import { nightly } from "../src/nightly.ts";
import { fetchContext } from "../src/writer.ts";

const here = import.meta.dirname;
const bin = join(here, "..", "bin", "nightly.ts");
const harness = join(here, "fake-harness.mjs");
const fakeNode = join(here, "fake-digestif.mjs");
const fixture = (n: string) => join(here, "harness-fixtures", n);

let dir: string;
let data: string;
let repo: string;
let calls: string;
let harnessLog: string;
let own: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "digestif-hook-test-"));
  data = join(dir, "data");
  own = join(data, "behaviors", "nightly");
  repo = join(dir, "repo");
  calls = join(dir, "digestif.log");
  harnessLog = join(dir, "harness.log");
  mkdirSync(repo);
  mkdirSync(own, { recursive: true });
  execFileSync("git", ["init", "-q", "-b", "main"], { cwd: repo });
  const date = "2026-10-28T12:00:00";
  writeFileSync(join(repo, "f.txt"), "x");
  const env = { ...process.env, GIT_AUTHOR_NAME: "M", GIT_AUTHOR_EMAIL: "m@example.com", GIT_COMMITTER_NAME: "M", GIT_COMMITTER_EMAIL: "m@example.com", GIT_AUTHOR_DATE: date, GIT_COMMITTER_DATE: date, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_SYSTEM: "/dev/null" };
  execFileSync("git", ["add", "."], { cwd: repo, env });
  execFileSync("git", ["commit", "-q", "-m", "Add a retry to the fetcher"], { cwd: repo, env });
  writeFileSync(join(own, "config.json"), JSON.stringify({ harness }));
});
afterEach(() => {
  for (const k of ["FAKE_FIXTURE", "FAKE_DIGESTIF_LOG", "FAKE_LOG"]) delete process.env[k];
  rmSync(dir, { recursive: true, force: true });
});

const handoff = (extra: Record<string, unknown> = {}) => ({
  interface: 0,
  hook: "nightly",
  local_date: "2026-10-29",
  data_dir: data,
  digestif: fakeNode,
  api: null,
  sources: [{ id: "git", kind: "git", label: "Git", paths: [repo], yields: [] }],
  deadline: new Date(Date.now() + 3600_000).toISOString(),
  ...extra,
});
const env = (extra: Record<string, string> = {}) => ({ ...process.env, DIGESTIF_HOOK: "nightly", FAKE_DIGESTIF_LOG: calls, FAKE_LOG: harnessLog, FAKE_FIXTURE: fixture("note.txt"), ...extra });
const run = (h: unknown, e = env()) => spawnSync(process.execPath, [bin], { input: typeof h === "string" ? h : JSON.stringify(h), encoding: "utf8", env: e });
const recorded = () => (existsSync(calls) ? readFileSync(calls, "utf8").trim().split("\n").map((l) => JSON.parse(l) as { args: string[]; stdin: string }) : []);
const harnessCalls = () => (existsSync(harnessLog) ? readFileSync(harnessLog, "utf8").trim().split("\n").map((l) => JSON.parse(l) as { argv: string[]; stdin: string; pid: number; grandchild?: number }) : []);

test("a handoff drives one run: the day before local_date, the handoff's binary and headers, and the node's state logic is skipped", async () => {
  const seen: Record<string, string | string[] | undefined>[] = [];
  const server = createServer((req, res) => {
    seen.push(req.headers);
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ text: req.url === "/api/v0/brief" ? "API-BRIEF" : "API-RULES" }));
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  try {
    const url = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
    const headers = { Cookie: "hook_session=abc", "Digestif-Local": "1", "X-Extra": "kept" };
    const child = spawn(process.execPath, [bin], { env: env(), stdio: ["pipe", "ignore", "pipe"] });
    child.stdin.end(JSON.stringify(handoff({ api: { url, headers } })));
    const code = await new Promise<number | null>((r) => child.on("close", r));
    assert.equal(code, 0);
    assert.equal(seen.length, 2);
    for (const h of seen) {
      assert.equal(h["cookie"], "hook_session=abc");
      assert.equal(h["digestif-local"], "1");
      assert.equal(h["x-extra"], "kept");
    }
  } finally {
    server.close();
  }
  const [c, ...rest] = recorded();
  assert.deepEqual(c?.args, ["note", "--text", "-"]);
  assert.match(c!.stdin, /^Worked on:/);
  assert.equal(rest.length, 0);
  const [h] = harnessCalls();
  assert.ok(h!.stdin.includes("commit: Add a retry to the fetcher"), "the day before local_date");
  const system = h!.argv[h!.argv.indexOf("--system-prompt") + 1]!;
  assert.ok(system.includes("API-BRIEF") && system.includes("API-RULES"));
  // The state keeps no minute and no handled date, and lives under the behavior's own directory.
  const state = JSON.parse(readFileSync(join(own, "nightly.json"), "utf8")) as Record<string, unknown>;
  assert.equal(state["minute"], undefined);
  assert.equal(state["handled"], undefined);
  assert.ok(existsSync(join(own, "logs", "nightly-2026-10-29.log")));
  // The node owns once-per-date: a second spawn for the same date runs again, at any hour.
  assert.equal(run(handoff()).status, 0);
  assert.equal(recorded().length, 2);
});

test("a null api means an empty brief and empty rules, and config.json carries what the handoff does not", () => {
  writeFileSync(join(dir, "brief.txt"), "FILE-BRIEF");
  writeFileSync(join(own, "config.json"), JSON.stringify({ harness, brief: join(dir, "brief.txt"), allow: ["Athena"] }));
  assert.equal(run(handoff()).status, 0);
  assert.ok(harnessCalls()[0]!.argv.join("\n").includes("FILE-BRIEF"));
  // No config: the default harness is `claude` on PATH.
  rmSync(join(own, "config.json"));
  rmSync(harnessLog);
  const bindir = join(dir, "bin");
  mkdirSync(bindir);
  writeFileSync(join(bindir, "claude"), `#!/bin/sh\nexec ${process.execPath} ${harness} "$@"\n`, { mode: 0o755 });
  assert.equal(run(handoff(), env({ PATH: `${bindir}:${process.env["PATH"]}` })).status, 0);
  assert.equal(harnessCalls().length, 1);
  assert.equal(run(handoff(), env({ PATH: "/nonexistent" })).status, 1, "no harness: the run fails");
});

test("fetchContext takes the handoff's url and headers, keeps the loopback check, and null is empty", async () => {
  assert.deepEqual(await fetchContext(null), { brief: "", rules: "" });
  await assert.rejects(fetchContext({ url: "https://relay.example.org", headers: { Cookie: "x" } }), /loopback/);
});

test("a deny-layer refusal ticks quiet with the rule, never the text", () => {
  const leaked = join(dir, "leaky.txt");
  writeFileSync(leaked, `Worked on: writing to ${["jane", "example.org"].join("@")} about the fetcher.\nLearned: x\nStuck on: y\n`);
  assert.equal(run(handoff(), env({ FAKE_FIXTURE: leaked })).status, 0);
  assert.deepEqual(recorded().map((c) => c.args), [["tick", "--outcome", "quiet", "--note", "refused by the deny layer: pii: email address"]]);
  assert.ok(!readFileSync(join(own, "logs", "nightly-2026-10-29.log"), "utf8").includes("example.org"));
});

test("an interface other than 0, or a hook other than nightly, exits 2 and runs nothing", () => {
  for (const bad of [handoff({ interface: 1 }), handoff({ hook: "read" }), "not json", handoff({ deadline: "soon" })]) {
    assert.equal(run(bad).status, 2);
  }
  assert.equal(run(handoff(), env({ DIGESTIF_HOOK: "read" })).status, 2);
  assert.equal(recorded().length, 0);
  assert.equal(harnessCalls().length, 0);
  assert.equal(existsSync(join(own, "nightly.json")), false);
});

test("SIGTERM mid-run kills the harness's group, logs where, and exits non-zero", async () => {
  const child = spawn(process.execPath, [bin], { env: env({ FAKE_SLEEP_MS: "30000", FAKE_GRANDCHILD: "1" }), stdio: ["pipe", "ignore", "ignore"] });
  child.stdin.end(JSON.stringify(handoff()));
  const closed = new Promise<{ code: number | null; signal: string | null }>((r) => child.on("close", (code, signal) => r({ code, signal })));
  const until = Date.now() + 10_000;
  while (!(existsSync(harnessLog) && harnessCalls()[0]?.grandchild !== undefined) && Date.now() < until) await new Promise((r) => setTimeout(r, 50));
  const { pid, grandchild } = harnessCalls()[0]!;
  assert.ok(grandchild !== undefined);
  child.kill("SIGTERM");
  const { code, signal } = await closed;
  assert.ok(code !== 0 || signal !== null, "non-zero");
  assert.throws(() => process.kill(pid, 0), { code: "ESRCH" });
  assert.throws(() => process.kill(grandchild, 0), { code: "ESRCH" });
  assert.match(readFileSync(join(own, "logs", "nightly-2026-10-29.log"), "utf8"), /killed by SIGTERM at write/);
  assert.equal(recorded().length, 0);
});

test("no step starts within a minute of the deadline", async () => {
  const sources = [{ id: "git", kind: "git" as const, label: "Git", paths: [repo], yields: [], selected: true }];
  const base = { stateDir: own, selection: { sources }, now: new Date(), hookDate: "2026-10-29", node: fakeNode, writer: { harness } };
  process.env["FAKE_FIXTURE"] = fixture("note.txt");
  process.env["FAKE_DIGESTIF_LOG"] = calls;
  process.env["FAKE_LOG"] = harnessLog;
  const r = await nightly({ ...base, deadline: new Date(Date.now() + 30_000) });
  assert.equal(r.status, "failed");
  assert.equal(harnessCalls().length, 0);
  assert.equal(recorded().length, 0);
  assert.equal((await nightly({ ...base, deadline: new Date(Date.now() + 120_000) })).status, "posted");
});

test("bin/nightly-hook is executable and runs nightly.ts", () => {
  const launcher = join(here, "..", "bin", "nightly-hook");
  assert.equal(statSync(launcher).mode & 0o777, 0o755);
  const r = spawnSync(launcher, [], { input: JSON.stringify(handoff({ interface: 1 })), encoding: "utf8", env: env() });
  assert.equal(r.status, 2, r.stderr);
});
