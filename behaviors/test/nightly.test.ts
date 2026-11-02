// The nightly run with a fake clock, a fake harness and a fake `digestif` that records its calls.
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";
import { catchUpFrom, MAX_ATTEMPTS, MAX_CATCH_UP_DAYS, nightly, previousDate, readState, type NightlyOptions } from "../src/nightly.ts";
import { removesNothing, type ModelCheck } from "../src/checks.ts";

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
  const m = (await readState(random))!.minute!;
  assert.ok(m >= 180 && m <= 239);
  await assert.rejects(nightly({ ...opts("2026-10-29T02:00:00"), stateDir: join(dir, "bad"), minute: 240 }), /180\.\.239/);
});

test("it posts once per local date, the note of the day before, through `digestif note --text -`", async () => {
  const r = await nightly(opts("2026-10-29T03:21:00"));
  assert.deepEqual(r, { status: "posted", date: "2026-10-29" });
  const [c, ...rest] = recorded();
  assert.deepEqual(c?.args.slice(0, 4), ["note", "--text", "-", "--checks"]);
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
  const stdin = (JSON.parse(readFileSync(join(dir, "harness.log"), "utf8").split("\n")[0]!) as { stdin: string }).stdin;
  assert.ok(stdin.includes("commit: Add a retry to the fetcher") && !stdin.includes("Fix the docs build"));
  assert.equal(previousDate("2026-03-01"), "2026-02-28");
});

test("a day whose run failed on every try is not lost: the next run covers it too", async () => {
  process.env["FAKE_LOG"] = join(dir, "harness.log");
  const digests = () => readFileSync(join(dir, "harness.log"), "utf8").trim().split("\n").map((l) => JSON.parse(l) as { stdin: string; check?: string }).filter((c) => c.check === undefined).map((c) => c.stdin);
  // 10-27 is covered (nothing that day). Every try of 10-29, covering 10-28, fails.
  assert.equal((await nightly(opts("2026-10-28T03:21:00"))).status, "quiet");
  process.env["FAKE_FIXTURE"] = fixture("empty.txt");
  for (let i = 0; i < MAX_ATTEMPTS; i++) await nightly(opts(`2026-10-29T03:${21 + i}:00`));
  process.env["FAKE_FIXTURE"] = fixture("note.txt");
  assert.equal((await nightly(opts("2026-10-30T03:21:00"))).status, "posted");
  const last = digests().at(-1)!;
  assert.ok(last.includes("commit: Add a retry to the fetcher"), "10-28, which no run covered");
  assert.ok(last.includes("commit: Fix the docs build"), "10-29, the day this run covers");
  assert.match(readFileSync(join(stateDir, "logs", "nightly-2026-10-30.log"), "utf8"), /also covers 2026-10-28 to 2026-10-28: no run covered them/);
  assert.equal((await readState(stateDir))?.covered, "2026-10-29");
  assert.equal(catchUpFrom(undefined, "2026-10-29"), "2026-10-29", "nothing covered yet: one day");
  assert.equal(catchUpFrom("2026-10-28", "2026-10-29"), "2026-10-29");
  assert.equal(catchUpFrom("2026-09-01", "2026-10-29"), `2026-10-${29 - MAX_CATCH_UP_DAYS}`, "at most a week back");
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
  assert.deepEqual(recorded().at(-1)?.args.slice(0, 3), ["note", "--text", "-"]);
});

test("a quiet night names a command source that failed, never its output", async () => {
  const broken = join(dir, "broken");
  writeFileSync(broken, "#!/bin/sh\necho secret-output\nexit 2\n", { mode: 0o755 });
  const sel = { sources: [{ id: "command-athena", kind: "command" as const, label: "Athena", paths: [broken], yields: [], selected: true }] };
  const r = await nightly(opts("2026-10-29T03:21:00", { selection: sel }));
  assert.equal(r.status, "quiet");
  assert.deepEqual(recorded().map((c) => c.args), [["tick", "--outcome", "quiet", "--note", "no lines from Athena exited 2"]]);
});

// A command source that records the --since it was given, one per line, and prints one item.
function commandSource(id = "command-athena", body = "echo an item") {
  const program = join(dir, id);
  const seen = join(dir, `${id}.since`);
  writeFileSync(program, `#!/bin/sh\nwhile [ $# -gt 0 ]; do [ "$1" = --since ] && echo "$2" >> "${seen}"; shift; done\n${body}\n`, { mode: 0o755 });
  return {
    source: { id, kind: "command" as const, label: "Athena", paths: [program], yields: [], selected: true },
    since: () => readFileSync(seen, "utf8").trim().split("\n").map((t) => Date.parse(t) / 1000),
    rewrite: (b: string) => writeFileSync(program, `#!/bin/sh\nwhile [ $# -gt 0 ]; do [ "$1" = --since ] && echo "$2" >> "${seen}"; shift; done\n${b}\n`, { mode: 0o755 }),
  };
}
const seconds = (t: string) => at(t).getTime() / 1000;
const hookRun = (date: string, spawned: string, source: { id: string }, extra: Partial<NightlyOptions> = {}) =>
  nightly(opts(spawned, { hookDate: date, wall: () => at(spawned).getTime(), selection: { sources: [source as never] }, ...extra }));

test("a command source reads disjoint windows on consecutive nightly runs", async () => {
  const c = commandSource();
  assert.equal((await hookRun("2026-10-29", "2026-10-29T03:21:00", c.source)).status, "posted");
  assert.equal((await hookRun("2026-10-30", "2026-10-30T03:22:30", c.source)).status, "posted");
  assert.equal((await hookRun("2026-10-31", "2026-10-31T03:21:15", c.source)).status, "posted");
  assert.deepEqual(c.since(), [seconds("2026-10-28T00:00:00"), seconds("2026-10-29T03:21:00"), seconds("2026-10-30T03:22:30")]);
  assert.deepEqual((await readState(stateDir))?.command_read, { "command-athena": at("2026-10-31T03:21:15").getTime() });
});

test("a command source's window does not move until a run finishes", async () => {
  const c = commandSource();
  await hookRun("2026-10-29", "2026-10-29T03:21:00", c.source);
  process.env["FAKE_FIXTURE"] = fixture("empty.txt");
  assert.equal((await hookRun("2026-10-30", "2026-10-30T03:21:00", c.source)).status, "failed");
  process.env["FAKE_FIXTURE"] = fixture("note.txt");
  assert.equal((await hookRun("2026-10-30", "2026-10-30T03:26:00", c.source)).status, "posted");
  assert.equal((await hookRun("2026-10-31", "2026-10-31T03:21:00", c.source)).status, "posted");
  const t = seconds("2026-10-29T03:21:00");
  assert.deepEqual(c.since(), [seconds("2026-10-28T00:00:00"), t, t, seconds("2026-10-30T03:26:00")]);
});

test("a command source that fails on a finished run keeps the start it was given", async () => {
  const c = commandSource();
  const other = commandSource("command-notes");
  const both = { selection: { sources: [c.source, other.source] } };
  await hookRun("2026-10-29", "2026-10-29T03:21:00", c.source, both);
  c.rewrite("exit 3");
  assert.equal((await hookRun("2026-10-30", "2026-10-30T03:21:00", c.source, both)).status, "posted", "the other source still gives a note");
  c.rewrite("echo an item");
  await hookRun("2026-10-31", "2026-10-31T03:21:00", c.source, both);
  assert.deepEqual(c.since(), [seconds("2026-10-28T00:00:00"), seconds("2026-10-29T03:21:00"), seconds("2026-10-29T03:21:00")]);
  assert.deepEqual(other.since(), [seconds("2026-10-28T00:00:00"), seconds("2026-10-29T03:21:00"), seconds("2026-10-30T03:21:00")]);
});

test("a command source's window reaches back a week at most, and starts over once it is not chosen", async () => {
  const c = commandSource();
  const other = commandSource("command-notes");
  await hookRun("2026-10-01", "2026-10-01T03:21:00", c.source);
  await hookRun("2026-10-29", "2026-10-29T03:21:00", c.source);
  assert.equal(c.since().at(-1), seconds(`2026-10-21T00:00:00`));
  await hookRun("2026-10-30", "2026-10-30T03:21:00", other.source);
  assert.deepEqual((await readState(stateDir))?.command_read, { "command-notes": at("2026-10-30T03:21:00").getTime() });
  await hookRun("2026-10-31", "2026-10-31T03:21:00", c.source);
  assert.equal(c.since().at(-1), seconds("2026-10-30T00:00:00"));
});

test("a dry run moves no command source's window", async () => {
  const c = commandSource();
  await hookRun("2026-10-29", "2026-10-29T03:21:00", c.source);
  await hookRun("2026-10-30", "2026-10-30T03:21:00", c.source, { dryRun: true });
  assert.deepEqual((await readState(stateDir))?.command_read, { "command-athena": at("2026-10-29T03:21:00").getTime() });
});

test("a PII match is removed, not refused: the rest of the note goes over, and nothing logs the text", async () => {
  const leaked = join(dir, "leaky.txt");
  writeFileSync(leaked, `Worked on: the fetcher. Wrote to ${["jane", "example.org"].join("@")} about it.\nLearned: x\nStuck on: y\n`);
  process.env["FAKE_FIXTURE"] = leaked;
  const r = await nightly(opts("2026-10-29T03:21:00", { deny: [{ kind: "name", value: "Stuck" }] }));
  assert.deepEqual(r, { status: "posted", date: "2026-10-29" });
  const [c] = recorded();
  assert.equal(c!.stdin, "Worked on: the fetcher.\nLearned: x\n", "the sentence with the address, and the part the deny list emptied");
  assert.deepEqual(JSON.parse(c!.args[4]!)[0], {
    check: "pii",
    removals: [
      { part: "Worked on", cause: "detector", detector: "email address", count: 1 },
      { part: "Stuck on", cause: "deny_list", count: 1 },
    ],
  });
  assert.equal((await readState(stateDir))?.outcome, "posted");
  assert.ok(!readFileSync(join(stateDir, "logs", "nightly-2026-10-29.log"), "utf8").includes("example.org"), "the log names the type, not the text");
  assert.equal((await nightly(opts("2026-10-29T03:40:00"))).status, "already_handled");
});

test("a failing writer or hand-over is retried, at most three times a date, and logged", async () => {
  process.env["FAKE_FIXTURE"] = fixture("empty.txt");
  for (let i = 0; i < MAX_ATTEMPTS - 1; i++) assert.equal((await nightly(opts(`2026-10-29T03:${21 + i}:00`))).status, "failed");
  assert.equal(recorded().length, 0, "a try that will be retried tells nobody");
  const last = await nightly(opts("2026-10-29T03:30:00"));
  assert.deepEqual(last, { status: "gave_up", date: "2026-10-29", message: "the writer ended with empty" });
  assert.deepEqual(
    recorded().map((c) => c.args),
    [["tick", "--outcome", "failed", "--note", "The nightly note failed 3 times; the last try: the writer ended with empty"]],
    "the last try says why, for the Approvals page",
  );
  assert.equal((await nightly(opts("2026-10-29T04:00:00"))).status, "gave_up");
  assert.equal(recorded().length, 1);
  process.env["FAKE_FIXTURE"] = fixture("note.txt");
  process.env["FAKE_DIGESTIF_EXIT"] = "1";
  assert.equal((await nightly(opts("2026-10-30T03:21:00"))).status, "failed");
  process.env["FAKE_DIGESTIF_EXIT"] = "0";
  writeFileSync(calls, "");
  assert.equal((await nightly(opts("2026-10-30T03:30:00"))).status, "posted");
  assert.ok(readFileSync(join(stateDir, "logs", "nightly-2026-10-29.log"), "utf8").includes("failed (try 3/3)"));
});

test("the checked text goes over with each run's removals; nothing is held or refused", async () => {
  const rules: ModelCheck = { ask: async (v) => ({ status: "spans", spans: v.includes("backoff") ? [{ text: "backoff", cause: "rules" }] : [] }) };
  const r = await nightly(opts("2026-10-29T03:21:00", { rules, pii: removesNothing }));
  assert.equal(r.status, "posted");
  const [c] = recorded();
  assert.deepEqual(c!.args.slice(0, 4), ["note", "--text", "-", "--checks"]);
  assert.ok(!c!.stdin.includes("backoff") && c!.stdin.includes("Worked on:"), "the sentence holding the span is gone");
  assert.deepEqual(JSON.parse(c!.args[4]!)[1], { check: "rules", removals: [{ part: "Learned", cause: "rules", count: 1 }] });
  assert.ok(readFileSync(join(stateDir, "logs", "nightly-2026-10-29.log"), "utf8").includes("rules check: removed 1 from Learned (rules)"));
});

test("checks that empty the note write nothing: the day is Nothing to share", async () => {
  const pii: ModelCheck = { ask: async (v) => ({ status: "spans", spans: v.trim() === "" ? [] : [{ text: v.trim().split("\n")[0]!, cause: "person" }] }) };
  const r = await nightly(opts("2026-10-29T03:21:00", { pii, rules: removesNothing }));
  assert.equal(r.status, "emptied");
  assert.deepEqual(recorded().map((c) => c.args), [["tick", "--outcome", "quiet", "--note", "The checks removed everything, so there is nothing to share."]]);
});

test("a check that could not finish hands nothing over; a signed-out check is the signed-out tick", async () => {
  const down: ModelCheck = { ask: async () => ({ status: "could_not_finish", reason: "the model is unavailable" }) };
  assert.deepEqual(await nightly(opts("2026-10-29T03:21:00", { pii: down, rules: removesNothing })), { status: "failed", date: "2026-10-29", message: "the pii check could not finish: the model is unavailable" });
  assert.equal(recorded().length, 0);
  const out: ModelCheck = { ask: async () => ({ status: "could_not_finish", reason: "signed out", signedOut: true }) };
  assert.equal((await nightly(opts("2026-10-29T03:25:00", { pii: removesNothing, rules: out }))).status, "signed_out");
  assert.deepEqual(recorded().map((c) => c.args), [["tick", "--outcome", "harness_signed_out"]]);
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
