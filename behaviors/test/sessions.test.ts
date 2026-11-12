// Reading large Claude Code transcripts (digestif#233): a transcript is streamed and only its tail
// is read past a byte cap, and a source that spends its share of the deadline is abandoned while
// the others are read. Every transcript here is made up in a temp directory.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { closeSync, constants, existsSync, mkdirSync, mkdtempSync, openSync, readFileSync, rmSync, utimesSync, writeFileSync, writeSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";
import { readRecord, type SourceProgress } from "../src/extract.ts";
import { DEFAULT_MAX_TRANSCRIPT_BYTES, FINANCIAL_MARK, maxTranscriptBytes, readTranscript, ReadingOverran, sessionFiles, sessionsSince, skippedLine } from "../src/sessions.ts";
import type { Source } from "../src/sources.ts";
import { assistant, jsonl, user } from "./fixtures.ts";

let home: string;
before(() => {
  home = mkdtempSync(join(tmpdir(), "digestif-sessions-"));
});
after(() => rmSync(home, { recursive: true, force: true }));

const MB = 1024 * 1024;
const NOW = Date.UTC(2026, 10, 4, 12);
const SINCE = NOW - 36 * 3_600_000;
const iso = (ms: number) => new Date(ms).toISOString();

/** One project directory holding one transcript of `filler` megabytes of tool output between its first and last prompts. */
function bigTranscript(name: string, fillerMb: number): { dir: string; file: string } {
  const dir = join(home, ".claude", "projects", name);
  mkdirSync(dir, { recursive: true });
  const file = join(dir, "c0000000-0000-4000-8000-000000000001.jsonl");
  const fd = openSync(file, "w");
  writeSync(fd, jsonl([{ type: "ai-title", aiTitle: "Keep the build farm running", sessionId: "c" }, user("The first prompt, a week ago", iso(NOW - 7 * 86_400_000))]));
  // Tool results recorded as the user, as Claude Code records them: the bulk of a long session.
  const result = JSON.stringify(user([{ type: "tool_result", tool_use_id: "toolu_x", content: "x".repeat(64 * 1024) }], iso(NOW - 6 * 86_400_000))) + "\n";
  const reply = JSON.stringify(assistant("y".repeat(64 * 1024), iso(NOW - 6 * 86_400_000))) + "\n";
  const chunk = (result + reply).repeat(8);
  for (let n = 0; n < fillerMb * MB; n += Buffer.byteLength(chunk)) writeSync(fd, chunk);
  writeSync(fd, jsonl([user("Restart the stuck runner", iso(NOW - 3 * 3_600_000)), assistant("Restarted.", iso(NOW - 3 * 3_600_000 + 1000)), user("Now drain the queue", iso(NOW - 3_600_000))]));
  closeSync(fd);
  utimesSync(file, new Date(NOW), new Date(NOW));
  return { dir, file };
}

const claude = (paths: string[], extra: Partial<Source> = {}): Source => ({
  id: "claude-code",
  kind: "claude_code",
  label: "Claude Code sessions",
  paths,
  yields: [],
  selected: true,
  start: SINCE,
  recorded: true,
  ...extra,
});

test("a 100 MB transcript is read from its tail in seconds, and the note gets its last prompts and its title", async () => {
  const { dir } = bigTranscript("-Users-member-code-farm", 100);
  const logged: string[] = [];
  const began = Date.now();
  const record = await readRecord([claude([dir])], { firstNote: false, now: () => NOW, home, log: (l) => logged.push(l) });
  const took = Date.now() - began;
  assert.ok(took < 5_000, `read in ${took} ms`);
  assert.deepEqual(record.lines, ["session: Keep the build farm running", "prompt: Restart the stuck runner", "prompt: Now drain the queue"]);
  assert.deepEqual(record.failedSources, []);
  assert.equal(logged.length, 1);
  assert.match(logged[0]!, /^skipped 6[89] MB of session .*c0000000-0000-4000-8000-000000000001\.jsonl: read its last 32 MB$/);
});

test("the cap is DIGESTIF_MAX_TRANSCRIPT_BYTES when it is a positive whole number", () => {
  assert.equal(maxTranscriptBytes({}), DEFAULT_MAX_TRANSCRIPT_BYTES);
  assert.equal(DEFAULT_MAX_TRANSCRIPT_BYTES, 32 * MB);
  assert.equal(maxTranscriptBytes({ DIGESTIF_MAX_TRANSCRIPT_BYTES: "1048576" }), MB);
  for (const v of ["", "0", "-5", "32MB", "1.5"]) assert.equal(maxTranscriptBytes({ DIGESTIF_MAX_TRANSCRIPT_BYTES: v }), DEFAULT_MAX_TRANSCRIPT_BYTES, v);
});

test("a capped read keeps a line its tail begins on and drops the one it begins inside", async () => {
  const dir = join(home, "cap");
  mkdirSync(dir, { recursive: true });
  const file = join(dir, "s.jsonl");
  const last = JSON.stringify(user("The last prompt", iso(NOW))) + "\n";
  const middle = JSON.stringify(user("The middle prompt", iso(NOW - 1000))) + "\n";
  writeFileSync(file, JSON.stringify(user("The first prompt", iso(NOW - 2000))) + "\n" + middle + last);
  const exact = await readTranscript(file, { maxBytes: Buffer.byteLength(middle + last) });
  assert.deepEqual(exact.prompts.map((p) => p.text), ["The middle prompt", "The last prompt"]);
  const inside = await readTranscript(file, { maxBytes: Buffer.byteLength(middle + last) - 3 });
  assert.deepEqual(inside.prompts.map((p) => p.text), ["The last prompt"]);
  assert.equal(inside.skippedBytes > 0, true);
  const whole = await readTranscript(file, { maxBytes: MB });
  assert.equal(whole.prompts.length, 3);
  assert.equal(whole.skippedBytes, 0);
});

test("a spent budget stops the read with the file it was in", async () => {
  const dir = join(home, "budget");
  mkdirSync(dir, { recursive: true });
  const file = join(dir, "s.jsonl");
  writeFileSync(file, jsonl([user("One", iso(NOW - 1000)), user("Two", iso(NOW))]));
  let lines = 0;
  await assert.rejects(
    sessionsSince(dir, SINCE, Infinity, { budget: { spent: () => ++lines > 1 } }),
    (e: unknown) => e instanceof ReadingOverran && e.file === file,
  );
});

test("a source past its share is abandoned naming the file, and the other sources are read", async () => {
  const { dir } = bigTranscript("-Users-member-code-slow", 2);
  const repo = join(home, "code", "fetcher");
  mkdirSync(repo, { recursive: true });
  const env = { ...process.env, GIT_AUTHOR_NAME: "M", GIT_AUTHOR_EMAIL: "m@example.com", GIT_COMMITTER_NAME: "M", GIT_COMMITTER_EMAIL: "m@example.com", GIT_AUTHOR_DATE: iso(NOW - 3_600_000), GIT_COMMITTER_DATE: iso(NOW - 3_600_000), GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_SYSTEM: "/dev/null" };
  execFileSync("git", ["init", "-q", "-b", "main"], { cwd: repo, env });
  writeFileSync(join(repo, "f.txt"), "x");
  execFileSync("git", ["add", "."], { cwd: repo, env });
  execFileSync("git", ["commit", "-q", "-m", "Add a retry to the fetcher"], { cwd: repo, env });
  const git: Source = { id: "git", kind: "git", label: "Git repositories", paths: ["~/code/fetcher"], yields: [], selected: true, start: SINCE, recorded: true };
  // Every reading of the clock is a second: the transcripts' lines spend the share, git does not.
  let t = 0;
  const progress: SourceProgress[] = [];
  const record = await readRecord([claude([dir]), git], {
    firstNote: false,
    now: () => NOW,
    home,
    sourceBudgetMs: 10_000,
    elapsed: () => (t += 1000),
    onProgress: (p) => progress.push(p),
  });
  assert.deepEqual(record.failedSources, ["Claude Code sessions"]);
  assert.deepEqual(record.readSources, ["Git repositories"]);
  assert.deepEqual(record.overran, [{ source: "Claude Code sessions", file: "~/.claude/projects/-Users-member-code-slow/c0000000-0000-4000-8000-000000000001.jsonl" }]);
  assert.match(record.failures[0]!, /^Claude Code sessions: past its share of the deadline while reading ~\/\.claude\/projects\//);
  assert.deepEqual(
    record.lines.map((l) => l.replace(/ [0-9a-f]{12}: /, " <sha>: ")),
    ["commit: fetcher <sha>: Add a retry to the fetcher"],
  );
  assert.equal(record.ends["source:claude-code"], undefined, "an abandoned source does not move");
  assert.ok(progress.some((p) => p.source === "Claude Code sessions" && p.file?.endsWith(".jsonl") === true));
  assert.ok(progress.some((p) => p.source === "Git repositories"));
});

// Judging a project's paths (DIG-295): the reader once listed every enclosing folder of a project
// started inside a system temp root, and every child of each, and sat in that for the night.
// Every judging test but the slow-log one passes the fixture's `home` (an ancestor of its folder),
// which bounds the walk, so none lists the real temp folder above it. The slow-log test goes through
// sessionsSince, which reads the real disk, and so names a project that decodes to nothing.

const CAP = 50;

/** A folder to build a projects directory in, with one transcript in the project directory `name`. */
function judged(label: string, name: string): { root: string; projects: string; file: string; dir: string } {
  const root = join(home, label);
  const projects = join(root, "projects");
  const dir = join(projects, name);
  mkdirSync(dir, { recursive: true });
  const file = join(dir, "s.jsonl");
  writeFileSync(file, jsonl([user("A prompt", iso(NOW))]));
  return { root, projects, file, dir };
}

const touch = (p: string) => {
  mkdirSync(join(p, ".."), { recursive: true });
  writeFileSync(p, "");
};

test("a project under a temp root is judged by itself and its repository, and the folders above the root are never read (DIG-295)", async () => {
  const { root, projects, file, dir } = judged("temp-root", "-above-tmp-work-app");
  touch(join(root, "above", "main.beancount"));
  mkdirSync(join(root, "above", "tmp", "work", "app"), { recursive: true });
  const off: { tempRoots: string[] } = { tempRoots: [] };
  assert.deepEqual(await sessionFiles(projects, root, 0, home, undefined, off), [], "without the root, the books above mark it");
  rmSync(join(dir, FINANCIAL_MARK));
  const on = { tempRoots: [join(root, "above", "tmp")] };
  assert.deepEqual(await sessionFiles(projects, root, 0, home, undefined, on), [file]);
  assert.equal(existsSync(join(dir, FINANCIAL_MARK)), false);
});

/** A folder with more entries than the cap, each a directory, named `<prefix>NNNNN`. */
const crowd = (dir: string, prefix = "d"): void => {
  for (let n = 0; n <= CAP; n++) mkdirSync(join(dir, `${prefix}${String(n).padStart(5, "0")}`), { recursive: true });
};

/** More directories than the cap whose encoded name is `<head>-<tail>`, each spelled differently. */
const lookAlikes = (dir: string, head: string, tail: string): void => {
  for (let n = 0; n <= CAP; n++) mkdirSync(join(dir, `${head}${String.fromCharCode(0x4e00 + n)}${tail}`), { recursive: true });
};

test("a folder past the listing cap cannot be judged, so the project is skipped unjudged with no verdict kept, and the reading finishes (DIG-413)", async () => {
  // Decoding -work-app lists only root and work, both small. The cap is met by the one-level-down
  // check of work, which lists its child big, and the books in zz, after big, are never reached.
  const { root, projects, dir } = judged("cap-judged", "-work-app");
  mkdirSync(join(root, "work", "app"), { recursive: true });
  crowd(join(root, "work", "big"));
  const capped: Array<[string, string, number]> = [];
  const off = { tempRoots: [], maxJudgedEntries: CAP, onCappedJudgement: (d: string, f: string, m: number) => capped.push([d, f, m]) };
  assert.deepEqual(await sessionFiles(projects, root, 0, home, undefined, off), [], "past the cap, the skip fails closed");
  assert.deepEqual(capped, [[dir, join(root, "work", "big"), CAP]], "the folder that gave up is reported with the cap");
  assert.equal(existsSync(join(dir, FINANCIAL_MARK)), false, "an unjudged project keeps no verdict");
  capped.length = 0;
  touch(join(root, "work", "zz", "main.beancount"));
  assert.deepEqual(await sessionFiles(projects, root, 0, home, undefined, { tempRoots: [], maxJudgedEntries: CAP + 10 }), [], "under the cap the books below are seen");
  assert.equal(existsSync(join(dir, FINANCIAL_MARK)), true, "and that verdict is kept");
  assert.equal(capped.length, 0);
});

test("a sibling past the cap does not hide books in another sibling: the verdict is financial and kept (DIG-413)", async () => {
  const { root, projects, dir } = judged("cap-sibling", "-work-app");
  mkdirSync(join(root, "work", "app"), { recursive: true });
  crowd(join(root, "work", "big"));
  touch(join(root, "work", "zz", "main.beancount"));
  const capped: string[] = [];
  assert.deepEqual(await sessionFiles(projects, root, 0, home, undefined, { tempRoots: [], maxJudgedEntries: CAP, onCappedJudgement: (_d, f) => capped.push(f) }), []);
  assert.equal(capped.length, 0, "books seen on another child are a verdict, not a cap");
  assert.equal(existsSync(join(dir, FINANCIAL_MARK)), true);
});

test("a project whose existing verdict meets a capped folder keeps the mark and is still skipped (DIG-413)", async () => {
  const { root, projects, dir } = judged("cap-mark", "-proj");
  crowd(join(root, "proj"), "y");
  writeFileSync(join(dir, FINANCIAL_MARK), "kept\n");
  const capped: string[] = [];
  assert.deepEqual(await sessionFiles(projects, root, 0, home, undefined, { tempRoots: [], maxJudgedEntries: CAP, onCappedJudgement: (_d, f) => capped.push(f) }), []);
  assert.equal(readFileSync(join(dir, FINANCIAL_MARK), "utf8"), "kept\n", "the mark is left alone, not forgotten");
  assert.deepEqual(capped, [join(root, "proj")], "every path is there, so the mark could not be told stale: the cap is reported");
});

test("a stale mark with its path gone skips the project on the mark, whatever the cap, and is not reported as capped (DIG-413)", async () => {
  // The name decodes to nothing and the one path a transcript names is gone, under a folder past the cap.
  const { root, projects, dir } = judged("cap-stale", "-nowhere");
  crowd(join(root, "proj"), "y");
  writeFileSync(join(dir, "t.jsonl"), jsonl([{ ...user("A prompt", iso(NOW)), cwd: join(root, "proj", "gone") }]));
  writeFileSync(join(dir, FINANCIAL_MARK), "kept\n");
  const told: Array<[string, string]> = [];
  const capped: string[] = [];
  const opts = { tempRoots: [], maxJudgedEntries: CAP, onCappedJudgement: (_d: string, f: string) => capped.push(f), onSkipped: (d: string, r: string) => told.push([d, r]) };
  assert.deepEqual(await sessionFiles(projects, root, 0, home, undefined, opts), []);
  assert.equal(readFileSync(join(dir, FINANCIAL_MARK), "utf8"), "kept\n");
  assert.equal(capped.length, 0, "skipped on its mark, not for the cap");
  assert.equal(told.length, 0);
  // With no mark the same project cannot be judged, and is skipped for the cap.
  rmSync(join(dir, FINANCIAL_MARK));
  assert.deepEqual(await sessionFiles(projects, root, 0, home, undefined, opts), []);
  assert.deepEqual(capped, [join(root, "proj")]);
  assert.equal(existsSync(join(dir, FINANCIAL_MARK)), false);
});

test("a project path with more entries than the cap at its own top level is skipped unjudged, with the books at the top unseen (DIG-413)", async () => {
  // The name decodes against the root alone, so the cap is met judging the path itself, not decoding it.
  const { root, projects, dir } = judged("cap-top", "-proj");
  touch(join(root, "proj", "main.beancount"));
  crowd(join(root, "proj"), "y");
  const capped: string[] = [];
  assert.deepEqual(await sessionFiles(projects, root, 0, home, undefined, { tempRoots: [], maxJudgedEntries: CAP, onCappedJudgement: (_d, f) => capped.push(f) }), [], "the ledger above the cap is never leaked");
  assert.deepEqual(capped, [join(root, "proj")]);
  assert.equal(existsSync(join(dir, FINANCIAL_MARK)), false);
});

test("a folder past the cap beside a project's enclosing folder caps the one-level-down check, and books on another path are still a verdict (DIG-413)", async () => {
  // Decoding -g-a-app lists root, g and g/a, all small; g/big is listed only one level down from g.
  const { root, projects, dir } = judged("cap-beside", "-g-a-app");
  mkdirSync(join(root, "g", "a", "app"), { recursive: true });
  crowd(join(root, "g", "big"), "z");
  const capped: string[] = [];
  const opts = { tempRoots: [], maxJudgedEntries: CAP, onCappedJudgement: (_d: string, f: string) => capped.push(f) };
  assert.deepEqual(await sessionFiles(projects, root, 0, home, undefined, opts), []);
  assert.deepEqual(capped, [join(root, "g", "big")], "the sibling whose listing gave up");
  assert.equal(existsSync(join(dir, FINANCIAL_MARK)), false);
  // A second path of the same project, from a transcript's cwd, holds books: the verdict is real and kept.
  writeFileSync(join(dir, "t.jsonl"), jsonl([{ ...user("Another prompt", iso(NOW)), cwd: join(root, "books") }]));
  touch(join(root, "books", "main.beancount"));
  capped.length = 0;
  assert.deepEqual(await sessionFiles(projects, root, 0, home, undefined, opts), []);
  assert.equal(capped.length, 0, "books seen on another path are a verdict, not a cap");
  assert.equal(existsSync(join(dir, FINANCIAL_MARK)), true);
});

test("a level of the root with more entries than the cap still decodes, streamed for the children that can match (DIG-413)", async () => {
  const { root, projects, dir } = judged("cap-decode", "-home-books");
  touch(join(root, "home", "books", "main.beancount"));
  crowd(root, "x");
  const capped: string[] = [];
  // home itself is the boundary: only its own top level is listed, so the root is listed by the decoding alone.
  const opts = { tempRoots: [], maxJudgedEntries: CAP, onCappedJudgement: (_d: string, f: string) => capped.push(f) };
  assert.deepEqual(await sessionFiles(projects, root, 0, join(root, "home"), undefined, opts), [], "decoded past the cap, the books mark it");
  assert.equal(existsSync(join(dir, FINANCIAL_MARK)), true);
  assert.equal(capped.length, 0);
});

test("a level whose matching children pass the cap cannot be decoded, but a transcript's own path still is judged (DIG-413)", async () => {
  const { root, projects, dir } = judged("cap-matches", "-a-b-c");
  lookAlikes(join(root, "a"), "b", "c");
  const capped: string[] = [];
  const opts = { tempRoots: [], maxJudgedEntries: CAP, onCappedJudgement: (_d: string, f: string) => capped.push(f) };
  assert.deepEqual(await sessionFiles(projects, root, 0, home, undefined, opts), [], "no branch resolved");
  assert.deepEqual(capped, [join(root, "a")]);
  assert.equal(existsSync(join(dir, FINANCIAL_MARK)), false);
  writeFileSync(join(dir, "t.jsonl"), jsonl([{ ...user("Another prompt", iso(NOW)), cwd: join(root, "books") }]));
  touch(join(root, "books", "main.beancount"));
  capped.length = 0;
  assert.deepEqual(await sessionFiles(projects, root, 0, home, undefined, opts), []);
  assert.equal(capped.length, 0, "the decoding gave up, the cwd path held books");
  assert.equal(existsSync(join(dir, FINANCIAL_MARK)), true);
  // A project with no transcript in the window is noted, not read; past the cap it is left unnoted, and not reported either.
  const quiet = judged("cap-matches-quiet", "-a-b-c");
  lookAlikes(join(quiet.root, "a"), "b", "c");
  capped.length = 0;
  assert.deepEqual(await sessionFiles(quiet.projects, quiet.root, Date.now() + 60_000, home, undefined, opts), []);
  assert.equal(capped.length, 0);
  assert.equal(existsSync(join(quiet.dir, FINANCIAL_MARK)), false);
});

test("one decoding branch past the cap does not end the others (DIG-413)", async () => {
  // -a-b-c is a/b/c or a-b/c: the first branch gives up, the second is a real project directory.
  const { root, projects, file, dir } = judged("cap-branch", "-a-b-c");
  lookAlikes(join(root, "a"), "b", "c");
  mkdirSync(join(root, "a-b", "c"), { recursive: true });
  const capped: string[] = [];
  const opts = { tempRoots: [], maxJudgedEntries: CAP, onCappedJudgement: (_d: string, f: string) => capped.push(f) };
  assert.deepEqual(await sessionFiles(projects, root, 0, home, undefined, opts), [file], "the sibling branch resolved, and holds no books");
  assert.equal(capped.length, 0);
  touch(join(root, "a-b", "c", "main.beancount"));
  assert.deepEqual(await sessionFiles(projects, root, 0, home, undefined, opts), [], "and its books are seen");
  assert.equal(existsSync(join(dir, FINANCIAL_MARK)), true);
});

test("decoding never lists a temp root, and a look-alike branch beside it still resolves (DIG-413)", async () => {
  // The name -tmp-scratch-x reads as tmp/scratch/x or tmp-scratch/x. tmp is the temp root, past the cap.
  const { root, projects, file, dir } = judged("cap-rival", "-tmp-scratch-x");
  crowd(join(root, "tmp"), "t");
  mkdirSync(join(root, "tmp-scratch", "x"), { recursive: true });
  const lists: string[] = [];
  const capped: string[] = [];
  const opts = { tempRoots: [join(root, "tmp")], maxJudgedEntries: CAP, onListing: (d: string) => void lists.push(d), onCappedJudgement: (_d: string, f: string) => capped.push(f) };
  assert.deepEqual(await sessionFiles(projects, root, 0, home, undefined, opts), [file]);
  assert.equal(lists.includes(join(root, "tmp")), false, "the temp root was never listed");
  assert.ok(lists.includes(root));
  assert.equal(capped.length, 0);
  assert.equal(existsSync(join(dir, FINANCIAL_MARK)), false);
});

test("a folder past the streaming ceiling cannot be decoded, is streamed once, and counts every project that reaches it (DIG-413)", async () => {
  const { root, projects, dir } = judged("cap-ceiling", "-home-books");
  const other = join(projects, "-home-other");
  mkdirSync(other, { recursive: true });
  writeFileSync(join(other, "s.jsonl"), jsonl([user("Another prompt", iso(NOW))]));
  touch(join(root, "home", "books", "main.beancount"));
  crowd(root, "x");
  crowd(root, "y");
  const lists: string[] = [];
  const told: string[] = [];
  const capped: string[] = [];
  const opts = {
    tempRoots: [],
    maxJudgedEntries: CAP,
    maxStreamedEntries: CAP + 20,
    onListing: (d: string) => void lists.push(d),
    onSkipped: (d: string, r: string) => void told.push(`${d} ${r}`),
    onCappedJudgement: (_d: string, f: string) => void capped.push(f),
  };
  assert.deepEqual(await sessionFiles(projects, root, 0, join(root, "home"), undefined, opts), [], "neither project is read");
  assert.equal(lists.filter((d) => d === root).length, 2, "the root is listed to the cap once and streamed once, for both projects");
  assert.equal(told.length, 2, "both are counted");
  assert.deepEqual(capped, [root], "the folder is reported once");
  assert.equal(existsSync(join(dir, FINANCIAL_MARK)), false);
});

/** A folder for tests that decode against the real root, outside the system temp folder, which may be huge. */
function realRoot(label: string): { base: string; done: () => void } {
  const base = mkdtempSync(join(import.meta.dirname, `.tmp-${label}-`));
  return { base, done: () => rmSync(base, { recursive: true, force: true }) };
}

/** A projects directory under `home` holding one transcript, named for the encoded path of `project`. */
function projectFor(home: string, project: string): { projects: string; dir: string } {
  const projects = join(home, ".claude", "projects");
  const dir = join(projects, project.replace(/[^a-zA-Z0-9]/g, "-"));
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "s.jsonl"), jsonl([user("A prompt", iso(NOW))]));
  return { projects, dir };
}

test("a temp folder that is the home directory or encloses it is no temp root for decoding: the project under it is judged (DIG-413)", async () => {
  const { base, done } = realRoot("guard");
  const old = process.env.TMPDIR;
  try {
    const h = join(base, "h");
    touch(join(h, "proj", "main.beancount"));
    const { projects, dir } = projectFor(h, join(h, "proj"));
    for (const tmp of [h, base]) {
      process.env.TMPDIR = tmp;
      rmSync(join(dir, FINANCIAL_MARK), { force: true });
      const sessions = await sessionsSince(projects, 0, Infinity, { home: h, log: () => undefined });
      assert.equal(sessions.length, 0, `with TMPDIR ${tmp === h ? "the home" : "above it"} the ledger in the project's own folder is seen`);
      assert.equal(existsSync(join(dir, FINANCIAL_MARK)), true);
    }
  } finally {
    if (old === undefined) delete process.env.TMPDIR;
    else process.env.TMPDIR = old;
    done();
  }
});

test("decoding against the real root never lists the system temp folder, whatever temp roots were chosen (DIG-413)", async () => {
  const { base, done } = realRoot("sysprune");
  const old = process.env.TMPDIR;
  try {
    const h = join(base, "h");
    const t = join(base, "t");
    touch(join(t, "proj", "main.beancount"));
    mkdirSync(h, { recursive: true });
    const { projects, dir } = projectFor(h, join(t, "proj"));
    process.env.TMPDIR = t;
    // The caller's own roots are none, yet the project under the system temp folder is not decoded, so not judged and read.
    const sessions = await sessionsSince(projects, 0, Infinity, { home: h, tempRoots: [], log: () => undefined });
    assert.equal(sessions.length, 1);
    assert.equal(existsSync(join(dir, FINANCIAL_MARK)), false);
    // Away from the system temp folder the same layout decodes and its ledger is seen.
    process.env.TMPDIR = join(base, "elsewhere");
    assert.equal((await sessionsSince(projects, 0, Infinity, { home: h, tempRoots: [], log: () => undefined })).length, 0);
    assert.equal(existsSync(join(dir, FINANCIAL_MARK)), true);
  } finally {
    if (old === undefined) delete process.env.TMPDIR;
    else process.env.TMPDIR = old;
    done();
  }
});

test("two projects reaching one capped folder list it once, are both skipped, and the folder is reported once (DIG-413)", async () => {
  // Both decode to g/a and g/b, small. Judging each lists g's children one level down, and g/big is past the cap.
  const { root, projects, dir } = judged("cap-memo", "-g-a");
  const other = join(projects, "-g-b");
  mkdirSync(other, { recursive: true });
  writeFileSync(join(other, "s.jsonl"), jsonl([user("Another prompt", iso(NOW))]));
  mkdirSync(join(root, "g", "a"), { recursive: true });
  mkdirSync(join(root, "g", "b"), { recursive: true });
  crowd(join(root, "g", "big"), "z");
  const lists = new Map<string, number>();
  const capped: Array<[string, string]> = [];
  const told: Array<[string, string, number]> = [];
  const opts = {
    tempRoots: [],
    maxJudgedEntries: CAP,
    onListing: (d: string) => void lists.set(d, (lists.get(d) ?? 0) + 1),
    onCappedJudgement: (d: string, f: string) => capped.push([d, f]),
    onSkipped: (d: string, r: string, n: number) => told.push([d, r, n]),
  };
  assert.deepEqual(await sessionFiles(projects, root, 0, home, undefined, opts), [], "both projects are skipped");
  assert.equal(lists.get(join(root, "g", "big")), 1, "the capped folder is not listed again");
  assert.equal(lists.get(join(root, "g")), 1);
  assert.equal(capped.length, 1, "and is reported once, with the first project judged");
  assert.equal(capped[0]![1], join(root, "g", "big"));
  assert.deepEqual(told.map((t) => t.slice(1)), [["capped", 1], ["capped", 1]], "every project dropped is counted");
  assert.equal(existsSync(join(dir, FINANCIAL_MARK)) || existsSync(join(other, FINANCIAL_MARK)), false, "no verdict of any kind came out of the memo");
});

test("the skipped line counts projects left unjudged past the cap (DIG-413)", () => {
  assert.equal(skippedLine({ factory: 0, temp: 0, capped: 0 }), undefined);
  assert.equal(skippedLine({ factory: 0, temp: 0, capped: 2 }), "skipped 2 transcripts before reading, 2 left unjudged past the listing cap");
  assert.equal(skippedLine({ factory: 1, temp: 2, capped: 1 }), "skipped 4 transcripts before reading, 1 under the factory's directory, 2 under a temp root, 1 left unjudged past the listing cap");
});

test("a capped judgement goes to the log option with the skipped count, and to stderr only without one (DIG-413)", async () => {
  // /etc is a real folder in the root: a cap of none makes the decoding of -etc give up listing the real root.
  const { projects, dir } = judged("cap-log", "-etc");
  const old = console.error;
  const errors: string[] = [];
  console.error = (...a: unknown[]) => void errors.push(a.join(" "));
  try {
    const logged: string[] = [];
    await sessionsSince(projects, 0, Infinity, { log: (l) => logged.push(l), maxJudgedEntries: 0 });
    assert.equal(errors.length, 0);
    assert.deepEqual(logged, [`judging ${dir} gave up: / has more than 0 entries, the project is not read this run`, "skipped 1 transcript before reading, 1 left unjudged past the listing cap"]);
    await sessionsSince(projects, 0, Infinity, { maxJudgedEntries: 0 });
    assert.ok(errors.some((l) => l.startsWith("digestif: judging ") && l.includes("gave up")), errors.join("|"));
  } finally {
    console.error = old;
  }
});

test("a project named exactly for a temp root is skipped without listing it (DIG-295)", async () => {
  const { root, projects, file, dir } = judged("named-root", "-private-tmp-claude-503");
  touch(join(root, "private", "tmp", "claude-503", "main.beancount"));
  assert.deepEqual(await sessionFiles(projects, root, 0, home, undefined, { tempRoots: [] }), [], "listed, the books in it mark the project");
  rmSync(join(dir, FINANCIAL_MARK));
  const on = { tempRoots: [join(root, "private", "tmp", "claude-503")] };
  assert.deepEqual(await sessionFiles(projects, root, 0, home, undefined, on), [file], "named for the root, it is not listed");
  assert.equal(existsSync(join(dir, FINANCIAL_MARK)), false);
});

test("idle projects side by side are judged off one listing of each folder, and the idle one with books is still marked (ISS-65357)", async () => {
  const { root, projects, file } = judged("idle-many", "-ai-live-app");
  mkdirSync(join(root, "ai", "live", "app"), { recursive: true });
  const idle = (n: number) => join(projects, `-ai-i${n}-repo`);
  for (let n = 0; n < 40; n++) {
    mkdirSync(join(root, "ai", `i${n}`, "repo", ".git"), { recursive: true });
    mkdirSync(idle(n), { recursive: true });
    const old = join(idle(n), "s.jsonl");
    writeFileSync(old, jsonl([user("An old prompt", iso(NOW - 30 * 86_400_000))]));
    utimesSync(old, new Date(NOW - 30 * 86_400_000), new Date(NOW - 30 * 86_400_000));
  }
  touch(join(root, "ai", "i7", "repo", "main.beancount"));
  const lists = new Map<string, number>();
  const options = { tempRoots: [], onListing: (d: string) => void lists.set(d, (lists.get(d) ?? 0) + 1) };
  assert.deepEqual(await sessionFiles(projects, root, SINCE, root, undefined, options), [file]);
  assert.deepEqual([...lists].filter(([, n]) => n > 1), [], "no folder is listed twice in one reading");
  assert.equal(lists.get(join(root, "ai")), 1);
  assert.equal(existsSync(join(idle(7), FINANCIAL_MARK)), true, "the idle project with books keeps its verdict");
  assert.equal(existsSync(join(idle(8), FINANCIAL_MARK)), false);
});

test("a budget spent while judging stops it naming the project directory (DIG-295)", async () => {
  const { root, projects, dir } = judged("budget-judged", "-code-app");
  mkdirSync(join(root, "code", "app"), { recursive: true });
  let calls = 0;
  await assert.rejects(
    sessionFiles(projects, root, 0, home, { spent: () => ++calls > 1 }, { tempRoots: [] }),
    (e: unknown) => e instanceof ReadingOverran && e.file === dir,
  );
});

test("a judgement slower than the threshold is reported with its directory and time (DIG-295)", async () => {
  const { root, projects, dir } = judged("slow-judged", "-code-app");
  mkdirSync(join(root, "code", "app"), { recursive: true });
  const told: Array<[string, number]> = [];
  let t = 0;
  const options = { tempRoots: [], clock: () => (t += 5000), onSlowJudgement: (d: string, ms: number) => told.push([d, ms]) };
  await sessionFiles(projects, root, 0, home, undefined, options);
  assert.deepEqual(told, [[dir, 5000]]);
  told.length = 0;
  await sessionFiles(projects, root, 0, home, undefined, { ...options, slowJudgementMs: 10_000 });
  assert.deepEqual(told, []);
});

test("a slow judgement goes to the log option, and to stderr only without one (DIG-295)", async () => {
  const nowhere = `digestif-test-${randomBytes(6).toString("hex")}-nowhere`;
  const { projects } = judged("slow-log", `-${nowhere}`);
  const old = [Date.now, console.error] as const;
  const errors: string[] = [];
  console.error = (...a: unknown[]) => void errors.push(a.join(" "));
  let t = 0;
  Date.now = () => (t += 5000);
  try {
    const logged: string[] = [];
    // sessionsSince judges the projects directory with the real home; its project directory holds a transcript, so the judging runs.
    await sessionsSince(projects, 0, Infinity, { log: (l) => logged.push(l), clock: () => 0 });
    assert.equal(errors.length, 0);
    assert.ok(logged.some((l) => /^judging .*-nowhere took \d+ ms$/.test(l)), logged.join("|"));
    await sessionsSince(projects, 0, Infinity, {});
    assert.ok(errors.some((l) => l.startsWith("digestif: judging ")), errors.join("|"));
  } finally {
    Date.now = old[0];
    console.error = old[1];
  }
});

test("a transcript last modified before the window is never opened (ISS-65288)", { timeout: 20_000 }, async () => {
  // Every transcript outside the window is a named pipe. A reader that opened one, for its prompts or
  // its cwd, would block on it: a watcher sees the reader waiting there, records it, and lets the read
  // go on (an open for writing that does not wait succeeds only while a reader holds the pipe). One
  // pipe inside the window must be seen opened, so a listing that dropped every pipe could not pass
  // this vacuously (ISS-66124).
  const nowhere = `digestif-test-${randomBytes(6).toString("hex")}-factory`;
  const projects = join(home, "factory", ".claude", "projects");
  const before = new Date(SINCE - 86_400_000);
  const all: string[] = [];
  const pipes = (dir: string, n: number): void => {
    mkdirSync(dir, { recursive: true });
    for (let i = 0; i < n; i++) {
      const p = join(dir, `old-${i}.jsonl`);
      execFileSync("mkfifo", [p]);
      utimesSync(p, before, before);
      all.push(p);
    }
  };
  const active = join(projects, `-${nowhere}-active`);
  pipes(active, 20);
  for (let n = 0; n < 5; n++) pipes(join(projects, `-${nowhere}-idle-${n}`), 4);
  // The filter is mtimeMs >= since: a millisecond before it is outside the window, since itself is inside.
  const justBefore = join(active, "since-1.jsonl");
  execFileSync("mkfifo", [justBefore]);
  utimesSync(justBefore, new Date(SINCE - 1), new Date(SINCE - 1));
  all.push(justBefore);
  const atSince = join(active, "since.jsonl");
  writeFileSync(atSince, jsonl([user("A prompt before the window", iso(SINCE - 3_600_000))]));
  utimesSync(atSince, new Date(SINCE), new Date(SINCE));
  const live = join(active, "live.jsonl");
  execFileSync("mkfifo", [live]);
  utimesSync(live, new Date(NOW), new Date(NOW));
  const file = join(active, "new.jsonl");
  writeFileSync(file, jsonl([user("Ship the agent factory", iso(NOW - 3_600_000))]));
  utimesSync(file, new Date(NOW), new Date(NOW));
  // A live transcript over the cap: only its last maxBytes and its first megabyte, for the title, are read.
  const big = join(active, "big.jsonl");
  const fd = openSync(big, "w");
  writeSync(fd, jsonl([{ type: "ai-title", aiTitle: "Keep the factory running", sessionId: "b" }]));
  const filler = JSON.stringify(assistant("y".repeat(64 * 1024), iso(NOW - 6 * 86_400_000))) + "\n";
  for (let n = 0; n < 8 * MB; n += Buffer.byteLength(filler)) writeSync(fd, filler);
  writeSync(fd, jsonl([user("Drain the factory queue", iso(NOW - 3_600_000))]));
  closeSync(fd);
  utimesSync(big, new Date(NOW), new Date(NOW));
  const maxBytes = 256 * 1024;
  const opened = new Set<string>();
  const watcher = setInterval(() => {
    for (const p of [...all, live]) {
      try {
        closeSync(openSync(p, constants.O_WRONLY | constants.O_NONBLOCK));
        opened.add(p);
      } catch {
        continue;
      }
    }
  }, 10);
  let bigBytes = 0;
  // Progress counts the source's bytes; the transcripts read before the big one (oldest first) are subtracted.
  let bigFrom: number | undefined;
  try {
    assert.deepEqual(await sessionFiles(projects, "/", SINCE, home, undefined, { tempRoots: [] }), [big, live, file, atSince]);
    const sessions = await sessionsSince(projects, SINCE, NOW, {
      maxBytes,
      onProgress: (p) => {
        if (p.file !== big) return;
        bigFrom ??= p.bytes;
        bigBytes = Math.max(bigBytes, p.bytes - bigFrom);
      },
    });
    assert.deepEqual(
      sessions.map((s) => [s.file, s.title]),
      [
        [big, "Keep the factory running"],
        [file, "Ship the agent factory"],
      ],
    );
    let read = 0;
    const transcript = await readTranscript(big, { maxBytes, onBytes: (n) => (read = Math.max(read, n)) });
    // The tail is read from the byte before it, so a tail that begins on a line's first byte keeps that line.
    assert.ok(transcript.bytesRead <= maxBytes + 1, `${transcript.bytesRead}`);
    assert.ok(read <= maxBytes + 1 + MB, `${read}`);
    assert.ok(bigBytes <= maxBytes + 1 + MB, `${bigBytes}`);
  } finally {
    clearInterval(watcher);
  }
  assert.deepEqual([...opened], [live]);
});
