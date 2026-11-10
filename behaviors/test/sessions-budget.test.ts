// DIG-361: the sessions source skips transcripts that are not the member's before it reads them,
// runs under a time budget and a byte budget that end it with what it has read (newest first), and
// reports how far it is while it reads. Every transcript here is made up in a temp directory.
import assert from "node:assert/strict";
import { closeSync, ftruncateSync, mkdirSync, mkdtempSync, openSync, readFileSync, rmSync, utimesSync, writeFileSync, writeSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";
import { readRecord, type SourceProgress } from "../src/extract.ts";
import { writeProgress } from "../src/hook.ts";
import { sessionsSince, type ReadingProgress } from "../src/sessions.ts";
import type { Source } from "../src/sources.ts";
import { jsonl, user } from "./fixtures.ts";

let home: string;
before(() => {
  home = mkdtempSync(join(tmpdir(), "digestif-budget-"));
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

test("400 factory transcripts and one 700 MB member transcript: only the member's tail is read, the rest are skipped by path", async () => {
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
  const sessions = await sessionsSince(projects, SINCE, NOW, {
    home: h,
    tempRoots: [],
    maxBytes: MB,
    log: (l) => logged.push(l),
    onProgress: (p) => void read.push(p.file),
    clock: Date.now,
  });
  assert.ok(Date.now() - began < 10_000, "finished well inside its budget");
  assert.deepEqual(sessions.map((s) => s.prompts.map((p) => p.text)), [["Fix the build", "Now ship it"]]);
  assert.ok(read.every((f) => f === file || f.startsWith(projects) && !f.includes("-devfactory-runs-")), `only the member's files were opened: ${[...new Set(read)].slice(0, 3).join(", ")}`);
  const line = logged.filter((l) => l.startsWith("skipped 400 transcripts"));
  assert.equal(line.length, 1, logged.join("\n"));
  assert.match(line[0]!, /^skipped 400 transcripts before reading, 400 under the factory's runs$/);
});

test("a temp root and a root the Rules deny are skipped too, and each is counted with its reason", async () => {
  const h = join(home, "two");
  const projects = join(h, ".claude", "projects");
  mkdirSync(join(h, "code", "app"), { recursive: true });
  transcript(projects, join(h, "code", "app"), "mine", ["A member prompt"]);
  transcript(projects, join(h, "scratch", "x"), "t1", ["In a temp root"]);
  transcript(projects, join(h, "scratch", "y"), "t2", ["In a temp root too"]);
  transcript(projects, join(h, "clients", "acme-corp", "site"), "d", ["For a denied client"]);
  const logged: string[] = [];
  const sessions = await sessionsSince(projects, SINCE, NOW, {
    home: h,
    tempRoots: [join(h, "scratch")],
    deny: [{ kind: "name", value: "acme-corp" }],
    log: (l) => logged.push(l),
  });
  assert.deepEqual(sessions.map((s) => s.prompts[0]!.text), ["A member prompt"]);
  assert.deepEqual(logged, ["skipped 3 transcripts before reading, 2 under a temp root, 1 under a root the Rules deny"]);
});

test("the byte budget ends the source with the newest sessions it read, and the record says it was partial", async () => {
  const h = join(home, "bytes");
  const projects = join(h, ".claude", "projects");
  mkdirSync(join(h, "code", "app"), { recursive: true });
  for (let i = 0; i < 5; i++) transcript(projects, join(h, "code", "app"), `s${i}`, [`Prompt ${i}`, "x".repeat(1000)], NOW - i * 3_600_000);
  const partial: string[] = [];
  const sessions = await sessionsSince(projects, SINCE, NOW, { home: h, tempRoots: [], maxTotalBytes: 2000, onPartial: (why) => partial.push(why) });
  assert.deepEqual(sessions.map((s) => s.prompts[0]!.text), ["Prompt 0", "Prompt 1"], "newest first, stopped at the budget");
  assert.deepEqual(partial, ["bytes"]);
});

test("slow parsing: the source stops at its time budget, returns what it read, and the note carries the partial-reading line", async () => {
  const h = join(home, "slow");
  const dir = join(h, ".claude", "projects", encoded(join(h, "code", "app")));
  mkdirSync(dir, { recursive: true });
  mkdirSync(join(h, "code", "app"), { recursive: true });
  for (let i = 0; i < 6; i++) {
    const f = join(dir, `s${i}.jsonl`);
    writeFileSync(f, jsonl([user(`Prompt ${i} a`, iso(NOW - 3000)), user(`Prompt ${i} b`, iso(NOW - 2000)), user(`Prompt ${i} c`, iso(NOW - 1000))]));
    utimesSync(f, new Date(NOW - i * 3_600_000), new Date(NOW - i * 3_600_000));
  }
  // Every reading of the clock is a second, so the lines spend the share.
  let t = 0;
  const record = await readRecord([claude([dir])], { firstNote: false, now: () => NOW, home: h, sourceBudgetMs: 8_000, elapsed: () => (t += 1000), tempRoots: [] });
  assert.deepEqual(record.failedSources, []);
  assert.deepEqual(record.readSources, ["Claude Code sessions"]);
  assert.deepEqual(record.partial, [{ source: "Claude Code sessions", reason: "time" }]);
  assert.ok(record.lines.some((l) => l.includes("Prompt 0 a")), "the newest session is in");
  assert.ok(!record.lines.some((l) => l.includes("Prompt 5")), "the oldest is not");
  assert.ok(record.ends["source:claude-code"] !== undefined, "the day is read through, not failed");
});

test("progress advances as bytes are read: elapsed time and bytes change, and progress.json follows", async () => {
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
  for (const p of seen) {
    const sp: SourceProgress = { source: "Claude Code sessions", file: p.file, bytes: p.bytes, elapsedMs: p.elapsedMs };
    writeProgress(state, "read", [claude([projects])], sp);
    written.add(readFileSync(join(state, "progress.json"), "utf8"));
  }
  assert.ok(written.size >= 3, "progress.json changed while the read went on");
  const last = JSON.parse([...written].at(-1)!) as { reading: { bytes: number; elapsed_ms: number } };
  assert.ok(last.reading.bytes >= 6 * MB && last.reading.elapsed_ms > 0);
});
