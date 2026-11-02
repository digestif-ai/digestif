// The record from a fake ~/.claude/projects tree and a fake repository, pinned: where each source
// starts, the first note's reach, owned authors, the oldest-first limit and where a note ends.
import { execFile, execFileSync } from "node:child_process";
import { promisify } from "node:util";
import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { commandLines, MAX_COMMAND_LINES, MAX_LINE_CHARS } from "../src/command.ts";
import { readRecord, type ReadOptions } from "../src/extract.ts";
import { isBookkeeping } from "../src/git.ts";
import { dateTimeWithOffset, firstNoteCutoff, FIRST_NOTE_ITEMS, limitOldestFirst, parseOffset, RECORD_LIMIT, render, type Item } from "../src/record.ts";
import { itemLine, MAX_ITEM_CHARS, promptText, sessionFiles } from "../src/sessions.ts";
import { chosen, parseSelection, type Source } from "../src/sources.ts";
import { build, jsonl, user, type Fixture } from "./fixtures.ts";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

let fx: Fixture;
let sha: (subject: string) => string;
before(() => {
  fx = build();
  const log = execFileSync("git", ["-C", fx.repo, "log", "--format=%H %s"], { encoding: "utf8" });
  sha = (subject) => log.split("\n").find((l) => l.endsWith(` ${subject}`))!.split(" ")[0]!;
});
after(() => fx.remove());

const SINCE = "2026-11-01T03:50:00-05:00";
const NOW = Date.UTC(2026, 9, 28, 23);
const at = (t: string) => Date.parse(t);
const read = (s: Source[], o: Partial<ReadOptions> = {}) => readRecord(s, { firstNote: false, now: () => NOW, home: fx.home, ...o });
/** Shas vary per run: a commit line reads with <sha> in its place. */
const masked = (lines: string[]) => lines.map((l) => l.replace(/ [0-9a-f]{12}: /, " <sha>: "));

const claude = (extra: Partial<Source> = {}): Source => ({
  id: "claude-code",
  kind: "claude_code",
  label: "Claude Code sessions",
  paths: ["~/.claude/projects"],
  yields: [],
  selected: true,
  ...extra,
});
const git = (extra: Partial<Source> = {}): Source => ({ id: "git", kind: "git", label: "Git repositories", paths: ["~/code/fetcher"], yields: [], selected: true, ...extra });
const repo = (extra: Record<string, unknown> = {}) => ({ id: "github.com/member/fetcher", name: "fetcher", paths: ["~/code/fetcher"], recorded: false, ...extra });
const long = "prompt: " + itemLine("Please rewrite the fetcher so that it " + "retries politely ".repeat(80));

test("the first note reads back to 100 items as far as 30 days, oldest first, every source in time order", async () => {
  const r = await read([claude(), git()], { firstNote: true });
  assert.deepEqual(masked(r.lines), [
    "session: Old work",
    "session: Set up the alpha repo with a CI pipeline",
    "commit: fetcher <sha>: Yesterday's commit The body says why.",
    "commit: fetcher <sha>: Start the fetcher The body says why.",
    "session: Why does the beta build fail on Linux?",
    "prompt: Try the Linux build with the older toolchain",
    "session: A prompt the file's mtime denies",
    "commit: fetcher <sha>: Add a retry to the fetcher The body says why.",
    "commit: fetcher <sha>: Document the fetcher The body says why.",
    "bookkeeping commit: fetcher <sha>: Merge branch 'retry'",
    "prompt: Add a retry to the fetcher and back off between attempts.",
    "prompt: the fonts are overlapping",
    "prompt: Add a retry to the fetcher",
    long,
  ]);
  assert.ok(r.lines.some((l) => l.includes(` ${sha("Start the fetcher").slice(0, 12)}: `)), "the repository and the sha");
  assert.ok(!r.lines.join("\n").includes("Tomorrow"), "nothing after the read");
  assert.ok(!r.lines.join("\n").includes("Subagent"), "another agent's conversation is not the member's");
  assert.equal(Array.from(long.slice("prompt: ".length)).length, MAX_ITEM_CHARS);
  // Where the note ends: approval moves each source there.
  assert.deepEqual(r.ends, {
    [`repository:${join(fx.home, "code", "fetcher")}`]: { at: at("2026-10-28T14:00:00Z"), sha: sha("Merge branch 'retry'") },
    "source:claude-code": { at: NOW },
  });
});

test("each source starts where the last approved note ended: a commit, a time", async () => {
  const r = await read([
    claude({ start: at("2026-10-28T13:00:00Z"), recorded: true }),
    git({ repositories: [repo({ start: at("2026-10-28T00:00:00Z"), sha: sha("Start the fetcher"), recorded: true })] }),
  ]);
  assert.deepEqual(masked(r.lines), [
    "commit: fetcher <sha>: Add a retry to the fetcher The body says why.",
    "commit: fetcher <sha>: Document the fetcher The body says why.",
    "bookkeeping commit: fetcher <sha>: Merge branch 'retry'",
    "session: Set up the alpha repo with a CI pipeline",
    "prompt: Add a retry to the fetcher and back off between attempts.",
    "prompt: the fonts are overlapping",
    "prompt: Add a retry to the fetcher",
    long,
  ]);
  assert.deepEqual(r.ends["repository:github.com/member/fetcher"], { at: at("2026-10-28T14:00:00Z"), sha: sha("Merge branch 'retry'") });
  // Nothing new: the repository stays at its commit.
  const quiet = await read([git({ repositories: [repo({ start: at("2026-10-28T14:00:00Z"), sha: sha("Merge branch 'retry'"), recorded: true })] })]);
  assert.deepEqual(quiet.lines, []);
  assert.deepEqual(quiet.ends["repository:github.com/member/fetcher"], { at: at("2026-10-28T14:00:00Z"), sha: sha("Merge branch 'retry'") });
});

test("a recorded commit rebased away falls back to committer time", async () => {
  const r = await read([git({ repositories: [repo({ start: at("2026-10-28T12:30:00Z"), sha: "0".repeat(40), recorded: true })] })]);
  assert.deepEqual(masked(r.lines), ["commit: fetcher <sha>: Document the fetcher The body says why.", "bookkeeping commit: fetcher <sha>: Merge branch 'retry'"]);
});

test("only the owned authors' commits enter the record, and the repository still moves past the others", async () => {
  const theirs = await read([git({ repositories: [repo({ start: at("2026-10-28T00:00:00Z"), sha: sha("Start the fetcher"), recorded: true })], authors: [{ email: "Someone@Example.com", recorded: true, start: 0 }] })]);
  assert.deepEqual(theirs.lines, []);
  assert.deepEqual(theirs.ends["repository:github.com/member/fetcher"], { at: at("2026-10-28T14:00:00Z"), sha: sha("Merge branch 'retry'") });
  assert.deepEqual(theirs.ends["author:someone@example.com"], { at: NOW });
  const mine = await read([git({ repositories: [repo({ start: at("2026-10-28T00:00:00Z"), sha: sha("Start the fetcher"), recorded: true })], authors: [{ email: "MEMBER@example.com", recorded: true, start: 0 }] })]);
  assert.equal(mine.lines.length, 3);
});

test("an author added later reads their last 24 hours in a repository that already has a point", async () => {
  const r = await read([
    git({
      repositories: [repo({ start: at("2026-10-28T14:00:00Z"), sha: sha("Merge branch 'retry'"), recorded: true })],
      authors: [{ email: "member@example.com", start: at("2026-10-28T11:00:00Z"), recorded: false }],
    }),
  ]);
  assert.deepEqual(masked(r.lines), [
    "commit: fetcher <sha>: Add a retry to the fetcher The body says why.",
    "commit: fetcher <sha>: Document the fetcher The body says why.",
    "bookkeeping commit: fetcher <sha>: Merge branch 'retry'",
  ]);
});

test("a repository approved later starts at the 24 hours before it was approved, never its history", async () => {
  const r = await read([git({ repositories: [repo({ start: at("2026-10-28T12:30:00Z"), recorded: false })], authors: [{ email: "member@example.com", start: 0, recorded: true }] })]);
  assert.deepEqual(masked(r.lines), ["commit: fetcher <sha>: Document the fetcher The body says why.", "bookkeeping commit: fetcher <sha>: Merge branch 'retry'"]);
});

test("the record limit reads oldest first: the rest waits, and the source ends at the last item read", async () => {
  const dir = join(fx.projects, "-Users-member-code-busy");
  mkdirSync(dir, { recursive: true });
  const base = Date.UTC(2026, 9, 30, 10);
  const entries = Array.from({ length: RECORD_LIMIT + 5 }, (_, i) => user(`Prompt ${i}`, new Date(base + i * 1000).toISOString()));
  writeFileSync(join(dir, "ffff0000-0000-4000-8000-000000000006.jsonl"), jsonl(entries));
  const busy = claude({ paths: [dir], start: base - 1, recorded: true });
  const r = await read([busy], { now: () => base + 3_600_000 });
  assert.equal(r.items.length, RECORD_LIMIT);
  assert.equal(r.read, RECORD_LIMIT + 5);
  assert.equal(r.lines[0], "session: Prompt 0");
  assert.equal(r.lines.at(-1), `prompt: Prompt ${RECORD_LIMIT - 1}`);
  assert.deepEqual(r.ends["source:claude-code"], { at: base + (RECORD_LIMIT - 1) * 1000 });
  const next = await read([{ ...busy, start: r.ends["source:claude-code"]!.at }], { now: () => base + 3_600_000 });
  assert.deepEqual(next.lines, ["session: Prompt 0", ...[0, 1, 2, 3, 4].map((i) => `prompt: Prompt ${RECORD_LIMIT + i}`)], "the next note reads the rest");
});

test("the first note's reach: the last 24 hours with 100 items in them, else back to 100, as far as 30 days", () => {
  const now = Date.UTC(2026, 9, 30);
  const item = (hoursAgo: number): Item => ({ key: "k", at: now - hoursAgo * 3_600_000, kind: "prompt", text: String(hoursAgo) });
  const full = Array.from({ length: FIRST_NOTE_ITEMS + 1 }, (_, i) => item(i / 10));
  assert.equal(firstNoteCutoff([...full, item(48)], now), now - 24 * 3_600_000, "a heavy day is read whole");
  const sparse = Array.from({ length: 150 }, (_, i) => item(i));
  assert.equal(firstNoteCutoff(sparse, now), now - 99 * 3_600_000, "back to the 100th item");
  assert.equal(firstNoteCutoff([item(2), item(40 * 24)], now), now - 24 * 3_600_000, "nothing past 30 days");
  assert.equal(firstNoteCutoff([item(2), item(20 * 24)], now), now - 20 * 24 * 3_600_000);
});

test("the limit never splits a moment, and stops at the record's characters", () => {
  const item = (at: number, text = "x"): Item => ({ key: "k", at, kind: "prompt", text });
  const l = limitOldestFirst([item(1), item(2), item(2), item(3)], 2);
  assert.deepEqual(l.kept.map((i) => i.at), [1]);
  assert.equal(l.through, 1);
  assert.ok(l.cut && l.cutKeys.has("k"));
  const big = limitOldestFirst(Array.from({ length: 10 }, (_, i) => item(i, "y".repeat(990))), 100, 3000);
  assert.equal(big.kept.length, 3);
  assert.deepEqual(limitOldestFirst([item(1)]).cut, false);
});

test("bookkeeping: merges with no message of their own, memory, plan and sync commits", () => {
  assert.ok(isBookkeeping({ message: "Merge branch 'retry'", merge: true }));
  assert.ok(isBookkeeping({ message: "Merge remote-tracking branch 'origin/main' into i1", merge: true }));
  assert.ok(!isBookkeeping({ message: "Merge pull request #12 from x/y\n\nAdd the fetcher", merge: true }), "a merge with a message of its own");
  assert.ok(isBookkeeping({ message: "Sync memory", merge: false }));
  assert.ok(isBookkeeping({ message: "auto-sync: 3 files", merge: false }));
  assert.ok(isBookkeeping({ message: "Update plans for the fetcher", merge: false }));
  assert.ok(isBookkeeping({ message: "memory: the fetcher retries", merge: false }));
  assert.ok(!isBookkeeping({ message: "Add a retry to the fetcher", merge: false }));
  assert.ok(!isBookkeeping({ message: "Synchronize the clocks", merge: false }));
});

test("render titles a session once, before its first prompt in the record, and keeps the first of equal lines", () => {
  const p = (at: number, text: string, title?: string): Item => ({ key: "s", at, kind: "prompt", text, ...(title === undefined ? {} : { title }) });
  assert.deepEqual(render([p(1, "a", "T"), p(2, "b", "T"), p(3, "a", "T"), p(4, "c")]), ["session: T", "prompt: a", "prompt: b", "prompt: c"]);
});

test("the sources_form picks the sources; empty means nothing is read", async () => {
  const gitOnly = await read(chosen([claude(), git()], { selected: ["git"] }), { firstNote: true });
  assert.ok(gitOnly.lines.every((l) => l.includes("commit: ")));
  assert.deepEqual((await read(chosen([claude(), git()], { selected: [] }))).lines, []);
  assert.deepEqual(chosen([claude(), git()]).map((s) => s.id), ["claude-code", "git"]);
});

test("a path that is a project directory, a missing path and a repository that is not one", async () => {
  const one: Source[] = [claude({ paths: [join(fx.projects, "-Users-member-code-beta"), join(fx.home, "nowhere")], start: at("2026-10-28T00:00:00Z"), recorded: true }), git({ paths: [fx.home] })];
  assert.deepEqual((await read(one)).lines, ["session: Why does the beta build fail on Linux?", "prompt: Try the Linux build with the older toolchain"]);
});

test("a project holding financial records is skipped under the projects directory (node/web/sources.ml, session_files)", async () => {
  const root = join(fx.home, "financial-root");
  const projects = join(root, "projects");
  const touch = (p: string) => {
    mkdirSync(dirname(join(root, p)), { recursive: true });
    writeFileSync(join(root, p), "");
  };
  const session = (name: string, cwd?: string) => {
    mkdirSync(join(projects, name), { recursive: true });
    const file = join(projects, name, "s.jsonl");
    writeFileSync(file, cwd === undefined ? "" : `{"type":"queue-operation"}\n${JSON.stringify({ type: "user", cwd: join(root, cwd) })}\n`);
    return file;
  };
  mkdirSync(join(root, "home/code/alpha/.git"), { recursive: true });
  touch("home/code/alpha/ledger.ts");
  touch("home/code/books/main.beancount");
  touch("home/code/nested/2026/Checking.QFX");
  mkdirSync(join(root, "home/code/repo/.git"), { recursive: true });
  touch("home/code/repo/main.ledger");
  mkdirSync(join(root, "home/code/repo/scripts"), { recursive: true });
  touch("home/code/my/app/a.ofx");
  mkdirSync(join(root, "home/code/my-app"), { recursive: true });
  const books = session("-home-code-books");
  session("-home-code-nested");
  session("-home-code-repo-scripts");
  session("-home-code-my-app");
  const alpha = session("-home-code-alpha");
  const gone = session("-home-code-gone");
  // A plain folder of books, not a repository, with a session started in a subfolder.
  touch("home/plain/books.beancount");
  mkdirSync(join(root, "home/plain/scripts"), { recursive: true });
  session("-home-plain-scripts");
  // Removed since: the name decodes to nothing, and the transcript's cwd is what is judged.
  session("-home-plain-2025", "home/plain/2025");
  session("-home-code-repo-wt", "home/code/repo/wt");
  const old = session("-home-code-old", "home/code/old");
  // Moved: the name decodes to an ordinary folder, the recorded cwd to the books.
  mkdirSync(join(root, "home/code/alpha2"), { recursive: true });
  session("-home-code-alpha2", "home/plain/scripts");
  // Non-ASCII: one dash per UTF-16 code unit, as Claude Code writes the name.
  touch("home/caf\u00e9/main.beancount");
  session("-home-caf-");
  touch("home/\u{1F4D2}books/main.beancount");
  session("-home---books");
  // A dated folder of books beside the session's folder, under a folder directly under home whose
  // name reads as finance, or under any plain folder deeper down.
  touch("home/Finance/2025/main.beancount");
  mkdirSync(join(root, "home/Finance/tools"), { recursive: true });
  session("-home-Finance-tools");
  touch("home/docs/personal/2025/Checking.qif");
  mkdirSync(join(root, "home/docs/personal/scripts"), { recursive: true });
  session("-home-docs-personal-scripts");
  // Not a folder of books: a repository's fixture beside the session's folder, a fixture two levels
  // down inside the session's own repository, and records one level down in a folder directly under
  // home whose name does not read as finance.
  mkdirSync(join(root, "home/work/team/ofxparse/.git"), { recursive: true });
  touch("home/work/team/ofxparse/sample.ofx");
  mkdirSync(join(root, "home/work/team/app"), { recursive: true });
  const fixture = session("-home-work-team-app");
  mkdirSync(join(root, "home/work/mono/.git"), { recursive: true });
  touch("home/work/mono/pkgs/fixtures/a.ofx");
  mkdirSync(join(root, "home/work/mono/pkgs/app"), { recursive: true });
  const mono = session("-home-work-mono-pkgs-app");
  touch("home/work/old/Statement.ofx");
  mkdirSync(join(root, "home/work/site"), { recursive: true });
  const site = session("-home-work-site");
  // Home's own top level and its direct folders do not enclose a project.
  touch("home/stray.ofx");
  touch("home/Downloads/Statement.QFX");
  assert.deepEqual(await sessionFiles(projects, root, 0, join(root, "home")), [alpha, gone, old, mono, site, fixture], "only the projects holding no financial records");
  assert.deepEqual(await sessionFiles(projects, root, Date.now() + 60_000, join(root, "home")), [], "only transcripts modified since");
  assert.deepEqual(await sessionFiles(dirname(books), root), [books], "chosen by path");
});

test("a session's title is the aiTitle it records, else its summary line, else its first prompt; equal titles once", async () => {
  const dir = join(fx.projects, "-Users-member-code-titled");
  mkdirSync(dir, { recursive: true });
  const at = (h: number) => `2026-10-30T${String(h).padStart(2, "0")}:00:00.000Z`;
  const toolResult = user(
    [
      {
        type: "tool_result",
        tool_use_id: "toolu_2",
        content: '{"aiTitle":"nested, not the session\'s"}',
      },
    ],
    at(9),
    {
      toolUseResult: { title: "A tool result's title" },
    },
  );
  writeFileSync(
    join(dir, "a1000000-0000-4000-8000-000000000001.jsonl"),
    jsonl([
      user("Add a retry", at(8)),
      toolResult,
      { type: "ai-title", aiTitle: "", sessionId: "a1" },
      {
        type: "ai-title",
        aiTitle: "Add a retry to the fetcher",
        sessionId: "a1",
      },
      { type: "ai-title", aiTitle: "A later title", sessionId: "a1" },
    ]),
  );
  writeFileSync(
    join(dir, "a2000000-0000-4000-8000-000000000002.jsonl"),
    jsonl([user("Resume the retry work", at(10)), { type: "assistant", aiTitle: "Add a retry to the fetcher" }]),
  );
  writeFileSync(
    join(dir, "a3000000-0000-4000-8000-000000000003.jsonl"),
    jsonl([
      { type: "summary", summary: "Speed up the loader", leafUuid: "x" },
      { type: "assistant", summary: "not a summary line" },
      user("Batch the writes", at(11)),
    ]),
  );
  writeFileSync(join(dir, "a4000000-0000-4000-8000-000000000004.jsonl"), jsonl([toolResult, user("Why is the build slow?", at(12))]));
  const { lines } = await readRecord([{ ...claude(), paths: [dir], start: Date.UTC(2026, 9, 30), recorded: true }], { firstNote: false, now: () => Date.UTC(2026, 9, 31) });
  assert.deepEqual(lines, [
    "session: Add a retry to the fetcher",
    "prompt: Add a retry",
    "prompt: Resume the retry work",
    "session: Speed up the loader",
    "prompt: Batch the writes",
    "session: Why is the build slow?",
  ]);
});

test("promptText reads only what the member typed", () => {
  assert.equal(promptText(user("hello", "t")), "hello");
  assert.equal(promptText(user([{ type: "text", text: "[Image #2] look" }], "t")), "look");
  assert.equal(promptText(user([{ type: "tool_result", content: "output" }], "t")), undefined);
  assert.equal(promptText(user("<system-reminder>x</system-reminder>", "t")), undefined);
  assert.equal(promptText(user("hello", "t", { isMeta: true })), undefined);
  assert.equal(promptText(user("hello", "t", { isSidechain: true })), undefined);
  assert.equal(promptText(user("This session is being continued from a previous conversation.", "t", { isCompactSummary: true })), undefined);
  assert.equal(promptText(user("hello", "t", { promptSource: "sdk" })), undefined);
  assert.equal(promptText(user("hello", "t", { promptSource: "system", origin: { kind: "auto-continuation" } })), undefined);
  assert.equal(promptText(user("hello", "t", { promptSource: "typed", origin: { kind: "human" } })), "hello");
  assert.equal(promptText(user("hello", "t", { promptSource: "queued" })), "hello");
  assert.equal(promptText(user("hello", "t", { promptSource: "suggestion_accepted" })), "hello");
  assert.equal(promptText({ type: "assistant", message: { role: "assistant", content: "hello" } }), undefined);
  assert.equal(promptText({ type: "user", message: { role: "assistant", content: "hello" } }), undefined);
  assert.equal(promptText("not an object"), undefined);
  assert.equal(itemLine("\n\n  two   words \nmore"), "two words more");
});


test("parseSelection takes the node's list or a list with a form, with each source's start", () => {
  assert.deepEqual(parseSelection([claude(), git()]).form, undefined);
  assert.deepEqual(parseSelection({ sources: [claude(), git()], form: { selected: ["git"] } }).form, { selected: ["git"] });
  assert.throws(() => parseSelection([{ id: "x" }]), /source/);
  assert.throws(() => parseSelection({ sources: [git()], form: { selected: "git" } }), /sources_form/);
  assert.throws(() => parseSelection(42), /expected/);
  const handed = parseSelection([
    { ...claude(), start: "2026-10-28T13:00:00.000Z", recorded: true },
    { ...git(), repositories: [{ id: "r", name: "fetcher", paths: ["/r"], start: "2026-10-28T00:00:00.000Z", recorded: true, sha: "abc" }], authors: [{ email: "m@example.com", start: null, recorded: false }] },
  ]).sources;
  assert.equal(handed[0]!.start, at("2026-10-28T13:00:00Z"));
  assert.deepEqual(handed[1]!.repositories, [{ id: "r", name: "fetcher", paths: ["/r"], start: at("2026-10-28T00:00:00Z"), recorded: true, sha: "abc" }]);
  assert.deepEqual(handed[1]!.authors, [{ email: "m@example.com", recorded: false }]);
});

test("the extract command prints the record the writer reads", async () => {
  const file = join(fx.home, "selection.json");
  writeFileSync(file, JSON.stringify({ sources: [claude(), git()], form: { selected: ["claude-code", "git"] } }));
  const run = promisify(execFile);
  const { stdout } = await run(process.execPath, ["bin/extract.ts", "--sources", file, "--now", new Date(NOW).toISOString(), "--home", fx.home]);
  assert.deepEqual(stdout, (await read([claude(), git()], { firstNote: true })).lines.join("\n") + "\n");
  await assert.rejects(run(process.execPath, ["bin/extract.ts"]), (e: { code: number; stderr: string }) => {
    assert.equal(e.code, 2);
    assert.match(e.stderr, /--sources is required/);
    return true;
  });
});

test("a date time carries its offset, the machine's at that instant unless one is named", () => {
  assert.equal(dateTimeWithOffset(Date.UTC(2026, 10, 1, 8, 50, 0, 900), -300), "2026-11-01T03:50:00-05:00");
  assert.equal(dateTimeWithOffset(Date.UTC(2026, 10, 1, 8, 50), 330), "2026-11-01T14:20:00+05:30");
  assert.equal(dateTimeWithOffset(Date.UTC(2026, 10, 1, 8, 50), 0), "2026-11-01T08:50:00+00:00");
  assert.equal(parseOffset("-0530"), -330);
  assert.equal(parseOffset("Z"), 0);
  assert.throws(() => parseOffset("+5"), /UTC offset/);
  const zone = process.env.TZ;
  process.env.TZ = "America/New_York";
  try {
    assert.equal(dateTimeWithOffset(new Date(2026, 9, 28).getTime()), "2026-10-28T00:00:00-04:00");
    assert.equal(dateTimeWithOffset(new Date(2026, 10, 2).getTime()), "2026-11-02T00:00:00-05:00");
  } finally {
    if (zone === undefined) delete process.env.TZ;
    else process.env.TZ = zone;
  }
});

test("a command source runs with --since its start, labels each line, and ends where it was spawned", async () => {
  const dir = join(fx.home, "cmd");
  mkdirSync(dir, { recursive: true });
  const program = join(dir, "activity");
  writeFileSync(program, '#!/bin/sh\necho "digestif: item opened: Command sources"\necho\necho "args: $*"\n', { mode: 0o755 });
  const broken = join(dir, "broken");
  writeFileSync(broken, "#!/bin/sh\necho partial\nexit 3\n", { mode: 0o755 });
  const cmd = (label: string, paths: string[], start?: number): Source => ({ id: `command-${label.toLowerCase()}`, kind: "command", label, paths, yields: [], selected: true, recorded: start !== undefined, ...(start === undefined ? {} : { start }) });
  const start = at("2026-10-28T00:00:00Z");
  const r = await read([cmd("Athena", [program, "--project", "digestif"], start), cmd("Broken", [broken], start)], { utcOffsetMinutes: 0 });
  assert.deepEqual(r.lines, ["Athena: digestif: item opened: Command sources", "Athena: args: --project digestif --since 2026-10-28T00:00:00+00:00"]);
  assert.deepEqual(r.failures, ["Broken exited 3"]);
  assert.deepEqual(r.ends, { "source:command-athena": { at: NOW } }, "a failed source reads the same window again");
  const west = await read([cmd("Athena", [program], start)], { utcOffsetMinutes: -300 });
  assert.ok(west.lines.includes("Athena: args: --since 2026-10-27T19:00:00-05:00"));
  const first = await read([cmd("Athena", [program])], { firstNote: true, utcOffsetMinutes: 0 });
  assert.ok(first.lines.includes("Athena: args: --since 2026-10-27T23:00:00+00:00"), "the first note asks for the last 24 hours");
  assert.deepEqual(parseSelection([cmd("Athena", [program])]).sources[0]?.kind, "command");
});

test("a command source is bounded: a hung program is ended, lines are capped and clipped", async () => {
  const dir = join(fx.home, "cmd-bounds");
  mkdirSync(dir, { recursive: true });
  const slow = join(dir, "slow");
  writeFileSync(slow, "#!/bin/sh\nsleep 5\n", { mode: 0o755 });
  const r = await commandLines([slow], SINCE, "Slow", 300);
  assert.deepEqual(r, { ok: false, reason: "Slow: still running after 0 seconds" });
  const long = join(dir, "long");
  writeFileSync(long, `#!/bin/sh\ni=0; while [ $i -lt ${MAX_COMMAND_LINES + 50} ]; do echo "line $i ${"x".repeat(MAX_LINE_CHARS + 100)}"; i=$((i+1)); done\n`, { mode: 0o755 });
  const l = await commandLines([long], SINCE, "Long");
  assert.ok(l.ok);
  assert.equal(l.lines.length, MAX_COMMAND_LINES);
  assert.ok(l.lines.every((x) => x.length <= MAX_LINE_CHARS));
  assert.deepEqual(await commandLines([join(dir, "missing")], SINCE, "Missing"), { ok: false, reason: `Missing: spawn ${join(dir, "missing")} ENOENT` });
});
