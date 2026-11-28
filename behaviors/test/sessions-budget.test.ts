// DIG-361: the sessions source skips transcripts that are not the member's before it reads them,
// runs under a time budget and a byte budget that end it with what it has read (newest first, saying
// how many of the oldest it left out, ISS-74092, DIG-214), and reports
// how far it is while it reads. Every transcript here is made up in a temp directory.
import assert from "node:assert/strict";
import { chmodSync, closeSync, existsSync, ftruncateSync, mkdirSync, mkdtempSync, openSync, readFileSync, rmSync, utimesSync, writeFileSync, writeSync } from "node:fs";
import { dirname, join } from "node:path";
import { after, before, test } from "node:test";
import { readRecord } from "../src/extract.ts";
import { readingWriter } from "../src/hook.ts";
import { ReadingOverran, sessionsSince, type LeftOut, type ReadingProgress } from "../src/sessions.ts";
import type { Source } from "../src/sources.ts";
import { hiddenAbove, jsonl, user } from "./fixtures.ts";

let home: string;
before(() => {
  home = mkdtempSync(join(import.meta.dirname, ".tmp-budget-"));
});
after(() => rmSync(home, { recursive: true, force: true }));

const MB = 1024 * 1024;
const NOW = Date.UTC(2026, 10, 9, 12);
const SINCE = NOW - 24 * 3_600_000;
const iso = (ms: number) => new Date(ms).toISOString();
/** A project directory's name for a path, as Claude Code writes it. */
const encoded = (p: string) => p.replace(/[^a-zA-Z0-9]/g, "-");

function transcript(projects: string, cwd: string, name: string, prompts: string[], at = NOW): string {
  const dir = join(projects, encoded(cwd));
  mkdirSync(dir, { recursive: true });
  const file = join(dir, `${name}.jsonl`);
  writeFileSync(file, jsonl(prompts.map((p, i) => user(p, iso(at - 1000 * (prompts.length - i))))));
  utimesSync(file, new Date(at), new Date(at));
  return file;
}

const claude = (paths: string[]): Source => ({ id: "claude-code", kind: "claude_code", label: "Claude Code sessions", paths, yields: [], selected: true, start: SINCE, recorded: true });

test("400 factory transcripts and one 700 MB member transcript: only the member's tail is read, the rest are skipped by path", { skip: hiddenAbove }, async () => {
  const projects = join(home, "one", ".claude", "projects");
  const h = join(home, "one");
  mkdirSync(join(h, "code", "app"), { recursive: true });
  for (let i = 0; i < 400; i++) transcript(projects, join(h, ".devfactory", "runs", `DF-${i}`, "work"), "s", [`Factory prompt ${i}`]);
  // The member's own session: 700 MB of nothing with its last prompts written at the end.
  const dir = join(projects, encoded(join(h, "code", "app")));
  mkdirSync(dir, { recursive: true });
  const file = join(dir, "own.jsonl");
  const size = 700 * MB;
  const tail = jsonl([user("Fix the build", iso(NOW - 2000)), user("Now ship it", iso(NOW - 1000))]);
  const fd = openSync(file, "w");
  ftruncateSync(fd, size);
  writeSync(fd, "\n" + tail, null, "utf8");
  closeSync(fd);
  // The prompts sit at the very end of the file.
  const end = openSync(file, "r+");
  writeSync(end, "\n" + tail, size - Buffer.byteLength("\n" + tail));
  closeSync(end);
  utimesSync(file, new Date(NOW), new Date(NOW));

  const logged: string[] = [];
  const read: string[] = [];
  const began = Date.now();
  let budgetChecks = 0;
  const sessions = await sessionsSince(projects, SINCE, NOW, {
    // The budget the nightly gives a source: ten minutes of the clock.
    budget: { spent: () => (budgetChecks++, Date.now() - began > 10 * 60_000) },
    home: h,
    tempRoots: [],
    maxBytes: MB,
    log: (l) => logged.push(l),
    onProgress: (p) => void read.push(p.file),
    clock: Date.now,
  });
  assert.ok(Date.now() - began < 10_000, "finished well inside its budget");
  // Skipped by path, the budget is asked about the member's lines and the few projects, not 400 files' worth.
  assert.ok(budgetChecks > 0 && budgetChecks < 450, `${budgetChecks} budget checks`);
  assert.deepEqual(sessions.map((s) => s.prompts.map((p) => p.text)), [["Fix the build", "Now ship it"]]);
  assert.ok(read.every((f) => f === file || f.startsWith(projects) && !f.includes("-devfactory-runs-")), `only the member's files were opened: ${[...new Set(read)].slice(0, 3).join(", ")}`);
  const line = logged.filter((l) => l.startsWith("skipped 400 transcripts"));
  assert.equal(line.length, 1, logged.join("\n"));
  assert.match(line[0]!, /^skipped 400 transcripts before reading, 400 under the factory's directory$/);
});

test("a temp root and the factory's other directories are skipped, each counted with its reason, and a denied name is not a root", { skip: hiddenAbove }, async () => {
  const h = join(home, "two");
  const projects = join(h, ".claude", "projects");
  mkdirSync(join(h, "code", "app"), { recursive: true });
  transcript(projects, join(h, "code", "app"), "mine", ["A member prompt"]);
  transcript(projects, join(h, "scratch", "x"), "t1", ["In a temp root"]);
  transcript(projects, join(h, "scratch", "y"), "t2", ["In a temp root too"]);
  transcript(projects, join(h, ".devfactory", "draft-triage", "z"), "f", ["In the factory's drafts"]);
  // Rules have no path roots: a project named for a client is the member's, whatever the deny list says.
  transcript(projects, join(h, "clients", "acme-corp", "site"), "d", ["For a client"]);
  const logged: string[] = [];
  const sessions = await sessionsSince(projects, SINCE, NOW, { home: h, tempRoots: [join(h, "scratch")], log: (l) => logged.push(l) });
  assert.deepEqual(sessions.map((s) => s.prompts[0]!.text).sort(), ["A member prompt", "For a client"]);
  assert.deepEqual(logged, ["skipped 3 transcripts before reading, 1 under the factory's directory, 2 under a temp root"]);
});

test("nothing under a skipped root is opened: an unreadable transcript there does not matter", { skip: hiddenAbove }, async () => {
  const h = join(home, "locked");
  const projects = join(h, ".claude", "projects");
  mkdirSync(join(h, "code", "app"), { recursive: true });
  transcript(projects, join(h, "code", "app"), "mine", ["A member prompt"]);
  const locked = [transcript(projects, join(h, ".devfactory", "runs", "DF-1", "work"), "s", ["Factory"]), transcript(projects, join(h, "scratch", "x"), "s", ["Temp"])];
  for (const f of locked) chmodSync(f, 0o000);
  try {
    const sessions = await sessionsSince(projects, SINCE, NOW, { home: h, tempRoots: [join(h, "scratch")] });
    assert.deepEqual(sessions.map((s) => s.prompts[0]!.text), ["A member prompt"]);
  } finally {
    for (const f of locked) chmodSync(f, 0o644);
  }
});

test("a budget spent while judging, before any transcript was read, fails the source: nothing is partial and nothing advances", async () => {
  const h = join(home, "judge");
  const projects = join(h, ".claude", "projects");
  transcript(projects, join(h, "code", "a"), "a", ["Newer"], NOW);
  transcript(projects, join(h, "code", "b"), "b", ["Older"], NOW - 3_600_000);
  let began = 0;
  const partial: string[] = [];
  // Spent once the second project's judging has begun: the first project was judged, none was read.
  await assert.rejects(
    sessionsSince(projects, SINCE, NOW, { home: h, tempRoots: [], budget: { spent: () => began >= 2 }, onProgress: () => void began++, onPartial: (w) => partial.push(w) }),
    (e: unknown) => e instanceof ReadingOverran,
  );
  assert.deepEqual(partial, []);
  let t = 0;
  const record = await readRecord([claude([projects])], {
    firstNote: false,
    now: () => NOW,
    home: h,
    tempRoots: [],
    sourceBudgetMs: 2_500,
    elapsed: () => (t += 1000),
  });
  assert.deepEqual(record.partial, []);
  assert.equal(record.ends["source:claude-code"], undefined, "the end does not move");
});

test("a budget-cut reading reads the newest first, leaves out the oldest, and its window still ends at now", async () => {
  const h = join(home, "paths");
  const first = join(h, "first");
  const second = join(h, "second");
  mkdirSync(first, { recursive: true });
  mkdirSync(second, { recursive: true });
  const write = (dir: string, name: string, text: string, at: number): void => {
    const f = join(dir, `${name}.jsonl`);
    writeFileSync(f, jsonl([user(text, iso(at - 1000)), user("x".repeat(1000), iso(at))]));
    utimesSync(f, new Date(at), new Date(at));
  };
  // Newest first across both paths: the cut falls between the middle and the oldest.
  write(first, "old", "The oldest", NOW - 5 * 3_600_000);
  write(second, "mid", "The middle", NOW - 3 * 3_600_000);
  write(first, "new", "The newest", NOW - 3_600_000);
  const once = await readRecord([claude([first, second])], { firstNote: false, now: () => NOW, home: h, tempRoots: [], maxSourceBytes: 2000 });
  assert.deepEqual(once.failedSources, []);
  assert.deepEqual(once.partial, [{ source: "Claude Code sessions", reason: "bytes", sessions: 1, lastActive: NOW - 5 * 3_600_000 }]);
  assert.deepEqual(once.lines.filter((l) => l.startsWith("session:")), ["session: The middle", "session: The newest"]);
  assert.equal(once.ends["source:claude-code"]!.at, NOW, "the window is read through: what was left out is older than all of it");
});

test("transcripts whose prompts interleave: the one active last is read, and what was left out was active no later than it says", async () => {
  const h = join(home, "interleave");
  const dir = join(h, "sessions");
  mkdirSync(dir, { recursive: true });
  const H = 3_600_000;
  const write = (name: string, prompts: [string, number][]): void => {
    const f = join(dir, `${name}.jsonl`);
    writeFileSync(f, jsonl(prompts.map(([text, at]) => user(text + " " + "x".repeat(600), iso(at)))));
    const last = prompts.at(-1)![1];
    utimesSync(f, new Date(last), new Date(last));
  };
  write("a", [["A one", NOW - 5 * H], ["A two", NOW - 3 * H]]);
  write("b", [["B one", NOW - 4 * H], ["B two", NOW - H]]);
  const left: LeftOut[] = [];
  const once = await sessionsSince(dir, SINCE, NOW, { home: h, tempRoots: [], maxTotalBytes: 1000, onPartial: (_why, l) => void left.push(l) });
  assert.deepEqual(once.flatMap((s) => s.prompts.map((p) => p.text.split(" x")[0]!)), ["B one", "B two"], "the session active last, whole");
  assert.deepEqual(left, [{ sessions: 1, lastActive: NOW - 3 * H }]);
});

test("a first note reaching back 30 days under a budget is written from the newest sessions, not weeks-old ones", async () => {
  const h = join(home, "first-note");
  const dir = join(h, "sessions");
  mkdirSync(dir, { recursive: true });
  const D = 24 * 3_600_000;
  for (let i = 0; i < 20; i++) {
    const at = NOW - (i + 1) * D - 3_600_000;
    const f = join(dir, `day${i}.jsonl`);
    writeFileSync(f, jsonl([user(`Day ${i + 1} ago`, iso(at - 1000)), user("x".repeat(1000), iso(at))]));
    utimesSync(f, new Date(at), new Date(at));
  }
  const today = join(dir, "today.jsonl");
  writeFileSync(today, jsonl([user("Today's work", iso(NOW - 2000)), user("x".repeat(1000), iso(NOW - 1000))]));
  utimesSync(today, new Date(NOW), new Date(NOW));
  const record = await readRecord([{ ...claude([dir]), start: undefined, recorded: false }], { firstNote: true, now: () => NOW, home: h, tempRoots: [], maxSourceBytes: 3000 });
  assert.deepEqual(record.failedSources, []);
  const titles = record.lines.filter((l) => l.startsWith("session:"));
  assert.ok(titles.includes("session: Today's work"), titles.join("\n"));
  assert.ok(!titles.includes("session: Day 20 ago"), "the oldest is what is left out");
  assert.equal(record.partial[0]?.sessions, 18);
  assert.equal(record.partial[0]?.lastActive, NOW - 3 * D - 3_600_000);
});

test("a budget that runs out after transcripts with nothing in the window fails the source: nothing yielded is not a partial reading", async () => {
  const h = join(home, "empty");
  const dir = join(h, "sessions");
  mkdirSync(dir, { recursive: true });
  // Modified last, so read first, but its only prompt is older than the window.
  const stale = join(dir, "stale.jsonl");
  writeFileSync(stale, jsonl([user("Before the window", iso(SINCE - 3_600_000)), user("y".repeat(3000), iso(SINCE - 3_600_000))]));
  utimesSync(stale, new Date(NOW), new Date(NOW));
  const fresh = join(dir, "fresh.jsonl");
  writeFileSync(fresh, jsonl([user("In the window", iso(NOW - 1000))]));
  utimesSync(fresh, new Date(NOW - 500), new Date(NOW - 500));
  const partial: string[] = [];
  await assert.rejects(
    sessionsSince(dir, SINCE, NOW, { home: h, tempRoots: [], maxTotalBytes: 2000, onPartial: (w) => partial.push(w) }),
    (e: unknown) => e instanceof ReadingOverran && e.file === fresh,
  );
  assert.deepEqual(partial, []);
  const record = await readRecord([claude([dir])], { firstNote: false, now: () => NOW, home: h, tempRoots: [], maxSourceBytes: 2000 });
  assert.deepEqual(record.failedSources, ["Claude Code sessions"]);
  assert.equal(record.ends["source:claude-code"], undefined, "the end does not move");
});

test("a look-alike beside a skipped root is read, and a temp root that is home or above it skips nothing", { skip: hiddenAbove }, async () => {
  const h = join(home, "alike");
  const projects = join(h, ".claude", "projects");
  mkdirSync(join(h, ".devfactory"), { recursive: true });
  mkdirSync(join(h, ".devfactory-notes", "a"), { recursive: true });
  mkdirSync(join(h, "scratch"), { recursive: true });
  mkdirSync(join(h, "scratch-pad", "b"), { recursive: true });
  transcript(projects, join(h, ".devfactory", "runs", "DF-1"), "f", ["The factory's"]);
  transcript(projects, join(h, ".devfactory-notes", "a"), "n", ["Beside the factory"]);
  transcript(projects, join(h, "scratch", "x"), "t", ["In the temp root"]);
  transcript(projects, join(h, "scratch-pad", "b"), "p", ["Beside the temp root"]);
  const texts = async (tempRoots: string[]): Promise<string[]> =>
    (await sessionsSince(projects, SINCE, NOW, { home: h, tempRoots })).map((s) => s.prompts[0]!.text).sort();
  assert.deepEqual(await texts([join(h, "scratch")]), ["Beside the factory", "Beside the temp root"]);
  for (const root of [h, dirname(h), h + "/"]) {
    assert.deepEqual(await texts([root]), ["Beside the factory", "Beside the temp root", "In the temp root"], `temp root ${root}`);
  }
});

test("the byte budget ends the source with the newest sessions it read, and the record says it was partial", { skip: hiddenAbove }, async () => {
  const h = join(home, "bytes");
  const projects = join(h, ".claude", "projects");
  mkdirSync(join(h, "code", "app"), { recursive: true });
  for (let i = 0; i < 5; i++) transcript(projects, join(h, "code", "app"), `s${i}`, [`Prompt ${i}`, "x".repeat(1000)], NOW - i * 3_600_000);
  const partial: string[] = [];
  const sessions = await sessionsSince(projects, SINCE, NOW, { home: h, tempRoots: [], maxTotalBytes: 2000, onPartial: (why) => partial.push(why) });
  assert.deepEqual(sessions.map((s) => s.prompts[0]!.text), ["Prompt 1", "Prompt 0"], "the newest, answered oldest first, stopped at the budget");
  assert.deepEqual(partial, ["bytes"]);
});

test("slow parsing: the source stops at its time budget, returns what it read, and the note carries the partial-reading line", async () => {
  const h = join(home, "slow");
  const dir = join(h, ".claude", "projects", encoded(join(h, "code", "app")));
  mkdirSync(dir, { recursive: true });
  mkdirSync(join(h, "code", "app"), { recursive: true });
  for (let i = 0; i < 6; i++) {
    const f = join(dir, `s${i}.jsonl`);
    const m = NOW - i * 3_600_000;
    writeFileSync(f, jsonl([user(`Prompt ${i} a`, iso(m - 3000)), user(`Prompt ${i} b`, iso(m - 2000)), user(`Prompt ${i} c`, iso(m - 1000))]));
    utimesSync(f, new Date(m), new Date(m));
  }
  // Every reading of the clock is a second, so the lines spend the share.
  let t = 0;
  const record = await readRecord([claude([dir])], { firstNote: false, now: () => NOW, home: h, sourceBudgetMs: 8_000, elapsed: () => (t += 1000), tempRoots: [] });
  assert.deepEqual(record.failedSources, []);
  assert.deepEqual(record.readSources, ["Claude Code sessions"]);
  assert.equal(record.partial.length, 1);
  const p = record.partial[0]!;
  assert.deepEqual({ source: p.source, reason: p.reason }, { source: "Claude Code sessions", reason: "time" });
  assert.ok(record.lines.some((l) => l.includes("Prompt 0 a")), "the newest session is in");
  assert.ok(!record.lines.some((l) => l.includes("Prompt 5")), "the oldest is not");
  const oldestRead = Math.max(...record.items.map((i) => Number(i.text.split(" ")[1])));
  assert.equal(p.sessions, 5 - oldestRead, "every transcript older than the oldest read is counted");
  assert.equal(p.lastActive, NOW - (oldestRead + 1) * 3_600_000, "the newest of them");
  assert.equal(record.ends["source:claude-code"]?.at, NOW, "read through, not failed");
});

test("progress advances as bytes are read: elapsed time and bytes change, and progress.json follows", { skip: hiddenAbove }, async () => {
  const h = join(home, "prog");
  const projects = join(h, ".claude", "projects");
  mkdirSync(join(h, "code", "app"), { recursive: true });
  for (let i = 0; i < 3; i++) transcript(projects, join(h, "code", "app"), `s${i}`, [`Prompt ${i}`, "x".repeat(2 * MB)], NOW - i * 3_600_000);
  let t = 0;
  const seen: ReadingProgress[] = [];
  await sessionsSince(projects, SINCE, NOW, { home: h, tempRoots: [], clock: () => (t += 100), onProgress: (p) => void seen.push(p) });
  assert.ok(seen.length >= 3, `${seen.length} reports`);
  for (let i = 1; i < seen.length; i++) {
    assert.ok(seen[i]!.elapsedMs >= seen[i - 1]!.elapsedMs && seen[i]!.bytes >= seen[i - 1]!.bytes, "neither goes back");
  }
  assert.ok(seen.at(-1)!.bytes >= 6 * MB && seen.at(-1)!.elapsedMs > seen[0]!.elapsedMs);
  const state = join(home, "prog-state");
  mkdirSync(state);
  const written = new Set<string>();
  // Through the hook's callback, with its one-a-second throttle on a clock that moves 400 ms a report.
  let now = 0;
  const onReading = readingWriter(state, [claude([projects])], () => (now += 400));
  for (const p of seen) {
    onReading({ source: "Claude Code sessions", file: p.file, bytes: p.bytes, elapsedMs: p.elapsedMs });
    written.add(readFileSync(join(state, "progress.json"), "utf8"));
  }
  assert.ok(written.size >= 3, "progress.json changed while the read went on");
  assert.ok(!existsSync(join(state, "progress.json.tmp")), "written by rename");
  const last = JSON.parse([...written].at(-1)!) as { reading: { bytes: number; elapsed_ms: number } };
  assert.ok(last.reading.bytes >= 6 * MB && last.reading.elapsed_ms > 0);
});
