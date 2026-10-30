// The nightly run with a fake clock, a fake harness and a fake `digestif` that records its calls.
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";
import { MAX_ATTEMPTS, nightly, previousDate, readState, type NightlyOptions } from "../src/nightly.ts";

const here = import.meta.dirname;
const harness = join(here, "fake-harness.mjs");
const fakeNode = join(here, "fake-digestif.mjs");
const fixture = (n: string) => join(here, "harness-fixtures", n);

let dir: string;
let stateDir: string;
let calls: string;
let repo: string;

function commit(subject: string, date: string) {
  writeFileSync(join(repo, "f.txt"), subject);
  const env = { ...process.env, GIT_AUTHOR_NAME: "M", GIT_AUTHOR_EMAIL: "m@example.com", GIT_COMMITTER_NAME: "M", GIT_COMMITTER_EMAIL: "m@example.com", GIT_AUTHOR_DATE: date, GIT_COMMITTER_DATE: date, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_SYSTEM: "/dev/null" };
  execFileSync("git", ["add", "."], { cwd: repo, env });
  execFileSync("git", ["commit", "-q", "-m", subject], { cwd: repo, env });
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "digestif-nightly-test-"));
  stateDir = join(dir, "state");
  calls = join(dir, "digestif.log");
  repo = join(dir, "repo");
  mkdirSync(repo);
  execFileSync("git", ["init", "-q", "-b", "main"], { cwd: repo });
  // Local times, no zone: the days are the machine's, whatever zone that is.
  commit("Add a retry to the fetcher", "2026-10-28T12:00:00");
  commit("Fix the docs build", "2026-10-29T12:00:00");
  process.env["FAKE_DIGESTIF_LOG"] = calls;
  process.env["FAKE_FIXTURE"] = fixture("note.txt");
});
afterEach(() => {
  for (const k of ["FAKE_DIGESTIF_LOG", "FAKE_DIGESTIF_EXIT", "FAKE_FIXTURE", "FAKE_EXIT", "FAKE_LOG"]) delete process.env[k];
  rmSync(dir, { recursive: true, force: true });
});

const selection = () => ({ sources: [{ id: "git", kind: "git" as const, label: "Git", paths: [repo], yields: [], selected: true }] });
const at = (t: string) => new Date(t);
const opts = (now: string, extra: Partial<NightlyOptions> = {}): NightlyOptions => ({ stateDir, selection: selection(), now: at(now), minute: 200, node: fakeNode, writer: { harness }, ...extra });
const recorded = () => (existsSync(calls) ? readFileSync(calls, "utf8").trim().split("\n").map((l) => JSON.parse(l) as { args: string[]; stdin: string }) : []);

test("the minute is chosen once, stored, and the run waits for it", async () => {
  assert.deepEqual(await nightly(opts("2026-10-29T03:19:00")), { status: "not_due", date: "2026-10-29", minute: 200 });
  assert.equal((await readState(stateDir))?.minute, 200);
  const r = await nightly(opts("2026-10-29T03:25:00", { minute: 230 }));
  assert.equal(r.status, "posted", "the stored minute wins over a later setting");
  assert.equal((await readState(stateDir))?.minute, 200);
  const random = join(dir, "random");
  await nightly({ ...opts("2026-10-29T02:00:00"), stateDir: random, minute: undefined as unknown as number });
  const m = (await readState(random))!.minute;
  assert.ok(m >= 180 && m <= 239);
  await assert.rejects(nightly({ ...opts("2026-10-29T02:00:00"), stateDir: join(dir, "bad"), minute: 240 }), /180\.\.239/);
});

test("it posts once per local date, the note of the day before, through `digestif note --text -`", async () => {
  const r = await nightly(opts("2026-10-29T03:21:00"));
  assert.deepEqual(r, { status: "posted", date: "2026-10-29" });
  const [c, ...rest] = recorded();
  assert.deepEqual(c?.args, ["note", "--text", "-"]);
  assert.match(c!.stdin, /^Worked on:/);
  assert.equal(rest.length, 0);
  assert.equal((await nightly(opts("2026-10-29T03:30:00"))).status, "already_handled");
  assert.equal((await nightly(opts("2026-10-29T20:00:00"))).status, "already_handled");
  assert.equal(recorded().length, 1);
  assert.equal((await readState(stateDir))?.handled, "2026-10-29");
  assert.equal((await nightly(opts("2026-10-30T03:30:00"))).status, "posted");
  assert.equal(recorded().length, 2);
});

test("a laptop closed at its minute posts when it next wakes", async () => {
  await nightly(opts("2026-10-29T02:00:00")); // asleep before the minute, and so on until morning
  const r = await nightly(opts("2026-10-29T09:41:00"));
  assert.equal(r.status, "posted");
  assert.equal(r.date, "2026-10-29");
  assert.equal(recorded().length, 1);
});

test("the digest the writer sees is the previous local day's", async () => {
  process.env["FAKE_LOG"] = join(dir, "harness.log");
  await nightly(opts("2026-10-29T03:21:00"));
  const stdin = (JSON.parse(readFileSync(join(dir, "harness.log"), "utf8").trim()) as { stdin: string }).stdin;
  assert.ok(stdin.includes("commit: Add a retry to the fetcher") && !stdin.includes("Fix the docs build"));
  assert.equal(previousDate("2026-03-01"), "2026-02-28");
});

test("--dry-run runs the pipeline, hands back the note, and posts and records nothing", async () => {
  const r = await nightly(opts("2026-10-29T01:00:00", { dryRun: true }));
  assert.equal(r.status, "dry_run");
  assert.match((r as { note: string }).note, /^Worked on:/);
  assert.equal(recorded().length, 0);
  assert.equal(existsSync(join(stateDir, "nightly.json")), false);
  assert.equal(existsSync(stateDir), false, "no log either");
  process.env["FAKE_FIXTURE"] = fixture("signed-out.txt");
  process.env["FAKE_EXIT"] = "1";
  assert.equal((await nightly(opts("2026-10-29T03:30:00", { dryRun: true }))).status, "signed_out");
  assert.equal(recorded().length, 0);
  assert.equal(existsSync(stateDir), false);
});

test("nothing to say records a quiet tick, once", async () => {
  const r = await nightly(opts("2026-10-29T03:21:00", { selection: { sources: [] } }));
  assert.equal(r.status, "quiet");
  assert.deepEqual(recorded().map((c) => c.args), [["tick", "--outcome", "quiet"]]);
  await nightly(opts("2026-10-29T03:40:00", { selection: { sources: [] } }));
  assert.equal(recorded().length, 1);
});

test("a harness with no login records harness_signed_out, once a day, and the note posts after sign-in", async () => {
  process.env["FAKE_FIXTURE"] = fixture("signed-out.txt");
  process.env["FAKE_EXIT"] = "1";
  assert.equal((await nightly(opts("2026-10-29T03:21:00"))).status, "signed_out");
  assert.equal((await nightly(opts("2026-10-29T03:26:00"))).status, "signed_out");
  assert.deepEqual(recorded().map((c) => c.args), [["tick", "--outcome", "harness_signed_out"]]);
  process.env["FAKE_FIXTURE"] = fixture("note.txt");
  process.env["FAKE_EXIT"] = "0";
  assert.equal((await nightly(opts("2026-10-29T10:00:00"))).status, "posted");
  assert.deepEqual(recorded().at(-1)?.args, ["note", "--text", "-"]);
});

test("a PII trip refuses the note, hands nothing over and records the tick", async () => {
  const leaked = join(dir, "leaky.txt");
  writeFileSync(leaked, `Worked on: writing to ${["jane", "example.org"].join("@")} about the fetcher.\nLearned: x\nStuck on: y\n`);
  process.env["FAKE_FIXTURE"] = leaked;
  const r = await nightly(opts("2026-10-29T03:21:00"));
  assert.deepEqual(r, { status: "refused", date: "2026-10-29", rule: "pii: email address" });
  assert.deepEqual(recorded().map((c) => c.args), [["tick", "--outcome", "quiet"]]);
  assert.equal((await readState(stateDir))?.outcome, "refused");
  assert.ok(!readFileSync(join(stateDir, "logs", "nightly-2026-10-29.log"), "utf8").includes("example.org"), "the log names the rule, not the text");
  assert.equal((await nightly(opts("2026-10-29T03:40:00"))).status, "already_handled");
});

test("a failing writer or hand-over is retried, at most three times a date, and logged", async () => {
  process.env["FAKE_FIXTURE"] = fixture("empty.txt");
  for (let i = 0; i < MAX_ATTEMPTS; i++) assert.equal((await nightly(opts(`2026-10-29T03:${21 + i}:00`))).status, "failed");
  assert.equal((await nightly(opts("2026-10-29T04:00:00"))).status, "gave_up");
  assert.equal(recorded().length, 0);
  process.env["FAKE_FIXTURE"] = fixture("note.txt");
  process.env["FAKE_DIGESTIF_EXIT"] = "1";
  assert.equal((await nightly(opts("2026-10-30T03:21:00"))).status, "failed");
  process.env["FAKE_DIGESTIF_EXIT"] = "0";
  assert.equal((await nightly(opts("2026-10-30T03:30:00"))).status, "posted");
  assert.ok(readFileSync(join(stateDir, "logs", "nightly-2026-10-29.log"), "utf8").includes("failed (try 3/3)"));
});

test("the business screen hook is a no-op by default and a hold still hands the note over", async () => {
  const r = await nightly(opts("2026-10-29T03:21:00", { business: { ask: async () => ({ hold: true, reason: "names a deal" }) } }));
  assert.equal(r.status, "posted");
  assert.ok(readFileSync(join(stateDir, "logs", "nightly-2026-10-29.log"), "utf8").includes("held for approval: names a deal"));
});

test("bin/nightly.ts: --now, --dry-run and the exit codes", () => {
  const sources = join(dir, "sources.json");
  writeFileSync(sources, JSON.stringify(selection()));
  const run = (extra: string[]) =>
    spawnSync(process.execPath, [join(here, "..", "bin", "nightly.ts"), "--sources", sources, "--state-dir", stateDir, "--node", fakeNode, "--harness", harness, ...extra], { encoding: "utf8", env: process.env });
  const dry = run(["--now", "2026-10-29T01:00", "--dry-run"]);
  assert.equal(dry.status, 0, dry.stderr);
  assert.match(dry.stdout, /^Worked on:/);
  assert.equal(recorded().length, 0);
  const real = run(["--now", "2026-10-29T03:30", "--minute", "200"]);
  assert.equal(real.status, 0, real.stderr);
  assert.match(real.stderr, /posted/);
  assert.equal(recorded().length, 1);
  assert.equal(run(["--now", "garbage"]).status, 2);
});
