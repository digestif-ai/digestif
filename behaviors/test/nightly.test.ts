// The nightly run with a fake clock, a fake harness and a fake `digestif` that records its calls.
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";
import { MAX_ATTEMPTS, nightly, noteTimeMinutes, readState, type NightlyOptions } from "../src/nightly.ts";
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
const opts = (now: string, extra: Partial<NightlyOptions> = {}): NightlyOptions => ({ stateDir, selection: selection(), now: at(now), noteTime: "03:20", node: fakeNode, writer: { harness }, ...extra });
/** Every call the run made of the node. */
const allCalls = () => (existsSync(calls) ? readFileSync(calls, "utf8").trim().split("\n").map((l) => JSON.parse(l) as { args: string[]; stdin: string }) : []);
/** The calls that hand the node a note or a tick; the problem record's are problems(). */
const recorded = () => allCalls().filter((c) => c.args[0] !== "problem");
/** What the run reported to the node's problem record, as job, kind and source. */
const problems = () => allCalls().filter((c) => c.args[0] === "problem").map((c) => c.args.slice(1).join(" "));

test("the run waits for Note time, any time of day, and keeps the Note time it was given", async () => {
  assert.deepEqual(await nightly(opts("2026-10-29T03:19:00")), { status: "not_due", date: "2026-10-29", noteTime: "03:20" });
  assert.equal((await readState(stateDir))?.note_time, "03:20");
  assert.equal((await nightly({ ...opts("2026-10-29T03:25:00"), noteTime: undefined as unknown as string })).status, "posted", "the saved Note time");
  const evening = join(dir, "evening");
  assert.equal((await nightly(opts("2026-10-29T09:00:00", { stateDir: evening, noteTime: "18:30" }))).status, "not_due");
  assert.equal((await nightly(opts("2026-10-29T18:30:00", { stateDir: evening, noteTime: "18:30" }))).status, "posted");
  const fresh = join(dir, "fresh");
  await nightly({ ...opts("2026-10-29T02:00:00"), stateDir: fresh, noteTime: undefined as unknown as string });
  assert.equal((await readState(fresh))?.note_time, "07:00", "none given: the node's default");
  await assert.rejects(nightly(opts("2026-10-29T02:00:00", { stateDir: join(dir, "bad"), noteTime: "25:00" })), /HH:MM/);
  assert.equal(noteTimeMinutes("7:05"), 425);
  assert.equal(noteTimeMinutes("07:60"), undefined);
});

test("a state written before Note time is read without its minute and covered days", async () => {
  mkdirSync(stateDir, { recursive: true });
  writeFileSync(join(stateDir, "nightly.json"), JSON.stringify({ version: 1, minute: 207, handled: "2026-10-28", covered: "2026-10-27", command_read: { x: 1 } }));
  assert.deepEqual(await readState(stateDir), { version: 1, handled: "2026-10-28" });
});

test("it posts once per local date, through `digestif note --text -`", async () => {
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

test("a laptop closed at Note time posts when it next wakes", async () => {
  await nightly(opts("2026-10-29T02:00:00")); // asleep before Note time, and so on until morning
  const r = await nightly(opts("2026-10-29T09:41:00"));
  assert.equal(r.status, "posted");
  assert.equal(r.date, "2026-10-29");
  assert.equal(recorded().length, 1);
});

const digests = () =>
  readFileSync(join(dir, "harness.log"), "utf8")
    .trim()
    .split("\n")
    .map((l) => JSON.parse(l) as { stdin: string; check?: string })
    .filter((c) => c.check === undefined)
    .map((c) => c.stdin);

test("standalone, the first note reads its reach, and the next starts where the note handed over ended", async () => {
  process.env["FAKE_LOG"] = join(dir, "harness.log");
  assert.equal((await nightly(opts("2026-10-29T03:21:00"))).status, "posted");
  assert.ok(digests()[0]!.includes("Add a retry to the fetcher") && !digests()[0]!.includes("Fix the docs build"), "nothing after the read");
  assert.ok(Object.keys((await readState(stateDir))!.record!).some((k) => k.startsWith("repository:")));
  assert.equal((await nightly(opts("2026-10-30T03:21:00"))).status, "posted");
  const second = digests().at(-1)!;
  assert.ok(second.includes("Fix the docs build") && !second.includes("Add a retry"), "told once");
});

test("a run that failed on every try moves nothing: the next run reads that work too", async () => {
  process.env["FAKE_LOG"] = join(dir, "harness.log");
  process.env["FAKE_FIXTURE"] = fixture("empty.txt");
  for (let i = 0; i < MAX_ATTEMPTS; i++) await nightly(opts(`2026-10-29T03:${21 + i}:00`));
  assert.equal((await readState(stateDir))?.record, undefined);
  process.env["FAKE_FIXTURE"] = fixture("note.txt");
  assert.equal((await nightly(opts("2026-10-30T03:21:00"))).status, "posted");
  const last = digests().at(-1)!;
  assert.ok(last.includes("Add a retry to the fetcher") && last.includes("Fix the docs build"));
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

test("nothing to say records a quiet tick, once, and the writing's problem closes", async () => {
  const r = await nightly(opts("2026-10-29T03:21:00", { selection: { sources: [] } }));
  assert.equal(r.status, "quiet");
  assert.deepEqual(recorded().map((c) => c.args), [["tick"]]);
  assert.deepEqual(problems(), ["resolve --job write_version"]);
  await nightly(opts("2026-10-29T03:40:00", { selection: { sources: [] } }));
  assert.equal(recorded().length, 1);
});

test("a harness with no login is a problem in writing, added to on each run, and the note posts after sign-in", async () => {
  process.env["FAKE_FIXTURE"] = fixture("signed-out.txt");
  process.env["FAKE_EXIT"] = "1";
  assert.equal((await nightly(opts("2026-10-29T03:21:00"))).status, "signed_out");
  assert.equal((await nightly(opts("2026-10-29T03:26:00"))).status, "signed_out");
  assert.equal(recorded().length, 0, "no tick: the run did not happen");
  assert.deepEqual(
    problems().filter((p) => p.startsWith("report")),
    ["report --job write_version --kind signed_out", "report --job write_version --kind signed_out"],
  );
  process.env["FAKE_FIXTURE"] = fixture("note.txt");
  process.env["FAKE_EXIT"] = "0";
  assert.equal((await nightly(opts("2026-10-29T10:00:00"))).status, "posted");
  assert.deepEqual(recorded().at(-1)?.args.slice(0, 3), ["note", "--text", "-"]);
});

test("a source that failed is its own problem, named by its label and never its output; one that read closes its own", async () => {
  const broken = join(dir, "broken");
  writeFileSync(broken, "#!/bin/sh\necho secret-output\nexit 2\n", { mode: 0o755 });
  const sel = { sources: [{ id: "command-athena", kind: "command" as const, label: "Athena", paths: [broken], yields: [], selected: true }] };
  const r = await nightly(opts("2026-10-29T03:21:00", { selection: sel }));
  assert.equal(r.status, "quiet");
  assert.deepEqual(recorded().map((c) => c.args), [["tick"]]);
  assert.deepEqual(problems(), ["report --job source --kind source_failed --source Athena", "resolve --job write_version"]);
  assert.ok(!JSON.stringify(allCalls()).includes("secret-output"));
  const fixed = join(dir, "fixed");
  writeFileSync(fixed, "#!/bin/sh\nexit 0\n", { mode: 0o755 });
  writeFileSync(calls, "");
  const again = { sources: [{ ...sel.sources[0]!, paths: [fixed] }] };
  await nightly(opts("2026-10-30T03:21:00", { selection: again }));
  assert.ok(problems().includes("resolve --job source --source Athena"), "the source read: its problem closes");
});

// The node's handoff: each source with its start, and first_note.
const hookRun = (date: string, spawned: string, sources: unknown[], extra: Partial<NightlyOptions> = {}) =>
  nightly(opts(spawned, { hookDate: date, firstNote: false, wall: () => at(spawned).getTime(), selection: { sources: sources as never }, ...extra }));

test("hook mode reads each source from the start the node handed over and hands the note over with where it ends", async () => {
  process.env["FAKE_LOG"] = join(dir, "harness.log");
  const program = join(dir, "athena");
  const seen = join(dir, "athena.since");
  writeFileSync(program, `#!/bin/sh\nwhile [ $# -gt 0 ]; do [ "$1" = --since ] && echo "$2" >> "${seen}"; shift; done\necho an item\n`, { mode: 0o755 });
  const head = execFileSync("git", ["-C", repo, "rev-parse", "HEAD~1"], { encoding: "utf8" }).trim();
  const sources = [
    { id: "git", kind: "git", label: "Git", paths: [repo], yields: [], selected: true, repositories: [{ id: "github.com/m/repo", name: "repo", paths: [repo], start: at("2026-10-28T12:00:00").getTime(), sha: head, recorded: true }], authors: null },
    { id: "command-athena", kind: "command", label: "Athena", paths: [program], yields: [], selected: true, start: at("2026-10-29T03:00:00").getTime(), recorded: true },
  ];
  assert.equal((await hookRun("2026-10-30", "2026-10-30T03:21:00", sources)).status, "posted");
  assert.equal(Date.parse(readFileSync(seen, "utf8").trim()), at("2026-10-29T03:00:00").getTime());
  const d = digests()[0]!;
  assert.ok(d.includes("commit: repo ") && d.includes("Fix the docs build") && !d.includes("Add a retry"));
  assert.ok(d.includes("Athena: an item"));
  const [c] = recorded();
  assert.deepEqual(c!.args.slice(0, 4), ["note", "--text", "-", "--ends"]);
  const ends = JSON.parse(readFileSync(c!.args[4]!, "utf8")) as Record<string, { at: string; sha?: string }>;
  assert.equal(ends["repository:github.com/m/repo"]?.sha, execFileSync("git", ["-C", repo, "rev-parse", "HEAD"], { encoding: "utf8" }).trim());
  assert.equal(ends["source:command-athena"]?.at, at("2026-10-30T03:21:00").toISOString());
  assert.equal((await readState(stateDir))?.record, undefined, "the node keeps the points");
});

test("hook mode from a node that hands over no first_note hands the note over without --ends", async () => {
  assert.equal((await hookRun("2026-10-30", "2026-10-30T03:21:00", [selection().sources[0]], { firstNote: undefined as unknown as boolean })).status, "posted");
  assert.deepEqual(recorded()[0]?.args, ["note", "--text", "-"]);
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
  assert.equal(recorded().length, 0, "nothing is handed over");
  const last = await nightly(opts("2026-10-29T03:30:00"));
  assert.deepEqual(last, { status: "gave_up", date: "2026-10-29", message: "the writer ended with empty" });
  assert.equal(recorded().length, 0, "no failed tick: the problem record says it");
  assert.deepEqual(
    problems().filter((p) => p.startsWith("report")),
    Array(MAX_ATTEMPTS).fill("report --job write_version --kind failed"),
    "each try is a problem in writing, never the run's own words",
  );
  assert.equal((await nightly(opts("2026-10-29T04:00:00"))).status, "gave_up");
  assert.equal(problems().filter((p) => p.startsWith("report")).length, MAX_ATTEMPTS);
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
  assert.deepEqual(recorded().map((c) => c.args), [["tick"]], "a quiet tick and no text of it anywhere");
});

test("a check that could not finish hands the note over unchecked, naming the check; the writing is not run again", async () => {
  const down: ModelCheck = { ask: async () => ({ status: "could_not_finish", reason: "the model is unavailable" }) };
  assert.deepEqual(await nightly(opts("2026-10-29T03:21:00", { pii: down, rules: removesNothing })), { status: "unchecked", date: "2026-10-29" });
  const [c] = recorded();
  assert.deepEqual(c!.args.slice(0, 3), ["note", "--text", "-"]);
  assert.deepEqual(c!.args.slice(5), ["--could-not-finish", "pii"]);
  assert.match(c!.stdin, /^Worked on:/, "what the agent wrote, for the checks to run on again");
  assert.equal((await nightly(opts("2026-10-29T03:40:00"))).status, "already_handled", "the date is handled");
  writeFileSync(calls, "");
  const out: ModelCheck = { ask: async () => ({ status: "could_not_finish", reason: "signed out", signedOut: true }) };
  assert.equal((await nightly(opts("2026-10-30T03:25:00", { pii: removesNothing, rules: out }))).status, "unchecked");
  assert.deepEqual(recorded()[0]!.args.slice(5), ["--could-not-finish", "rules", "--signed-out"]);
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
  const real = run(["--now", "2026-10-29T03:30", "--note-time", "03:20"]);
  assert.equal(real.status, 0, real.stderr);
  assert.match(real.stderr, /posted/);
  assert.equal(recorded().length, 1);
  assert.equal(run(["--now", "garbage"]).status, 2);
});
