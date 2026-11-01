// The day's digest lines from a fake ~/.claude/projects tree and a fake repository, pinned.
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { day, parseOffset, today } from "../src/day.ts";
import { commandLines, MAX_COMMAND_LINES, MAX_LINE_CHARS } from "../src/command.ts";
import { cap, extract, extractWithFailures, MAX_DIGEST_CHARS, MAX_LINES, render } from "../src/extract.ts";
import { itemLine, MAX_ITEM_CHARS, promptText } from "../src/sessions.ts";
import { chosen, parseSelection, type Source } from "../src/sources.ts";
import { build, jsonl, user, type Fixture } from "./fixtures.ts";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

let fx: Fixture;
before(() => {
  fx = build();
});
after(() => fx.remove());

const utc = (date: string) => day(date, 0);

function sources(): Source[] {
  return [
    {
      id: "claude-code",
      kind: "claude_code",
      label: "Claude Code sessions",
      paths: ["~/.claude/projects"],
      yields: ["Session titles from the last day"],
      selected: true,
    },
    { id: "git", kind: "git", label: "Git repositories", paths: ["~/code/fetcher"], yields: ["Commit subjects from the last day"], selected: true },
  ];
}

const expected = [
  "session: Why does the beta build fail on Linux?",
  "prompt: Try the Linux build with the older toolchain",
  "session: Set up the alpha repo with a CI pipeline",
  "prompt: Add a retry to the fetcher and back off between attempts.",
  "prompt: the fonts are overlapping",
  "prompt: Add a retry to the fetcher",
  "prompt: " + itemLine("Please rewrite the fetcher so that it " + "retries politely ".repeat(80)),
  "commit: Document the fetcher",
  "commit: Add a retry to the fetcher",
  "commit: Start the fetcher",
];

test("the day's lines: sessions, the member's prompts and commit subjects, in source order", async () => {
  const lines = render(await extract(sources(), utc("2026-10-28"), { home: fx.home }));
  assert.deepEqual(lines, expected);
  const long = lines[6]!;
  assert.ok(long.endsWith("…"));
  assert.equal(Array.from(long.slice("prompt: ".length)).length, MAX_ITEM_CHARS);
});

test("the sources_form picks the sources; empty means nothing leaves", async () => {
  const gitOnly = render(await extract(chosen(sources(), { selected: ["git"] }), utc("2026-10-28"), { home: fx.home }));
  assert.deepEqual(gitOnly, expected.slice(7));
  assert.deepEqual(await extract(chosen(sources(), { selected: [] }), utc("2026-10-28"), { home: fx.home }), []);
  assert.deepEqual(chosen(sources()).map((s) => s.id), ["claude-code", "git"]);
});

test("another day reads other lines, and a day with nothing is empty", async () => {
  const before = render(await extract(sources(), utc("2026-10-27"), { home: fx.home }));
  assert.deepEqual(before, ["session: Set up the alpha repo with a CI pipeline", "commit: Yesterday's commit"]);
  assert.deepEqual(render(await extract(sources(), utc("2026-10-25"), { home: fx.home })), []);
});

test("the day is read in the offset given: 2026-10-28 at +14:00 starts at 10:00Z the day before", async () => {
  const lines = render(await extract(sources(), day("2026-10-28", parseOffset("+14:00")), { home: fx.home }));
  assert.deepEqual(lines, [
    "session: Set up the alpha repo with a CI pipeline",
    "session: Why does the beta build fail on Linux?",
    "prompt: Try the Linux build with the older toolchain",
    "commit: Start the fetcher",
    "commit: Yesterday's commit",
  ]);
});

test("a path that is a project directory, a missing path and a repository that is not one", async () => {
  const one: Source[] = [
    { ...sources()[0]!, paths: [join(fx.projects, "-Users-member-code-beta"), join(fx.home, "nowhere")] },
    { ...sources()[1]!, paths: [fx.home] },
  ];
  assert.deepEqual(render(await extract(one, utc("2026-10-28"))), expected.slice(0, 2));
});

test("the lines are capped at MAX_LINES (node/web/sources.ml, max_lines)", async () => {
  const dir = join(fx.projects, "-Users-member-code-busy");
  mkdirSync(dir, { recursive: true });
  const entries = Array.from({ length: MAX_LINES + 5 }, (_, i) => user(`Prompt ${i}`, new Date(Date.UTC(2026, 9, 30, 10) + i * 1000).toISOString()));
  writeFileSync(join(dir, "ffff0000-0000-4000-8000-000000000006.jsonl"), jsonl(entries));
  const lines = await extract([{ ...sources()[0]!, paths: [dir] }], utc("2026-10-30"));
  assert.equal(lines.length, MAX_LINES);
  assert.deepEqual(lines[0], { kind: "session", text: "Prompt 0" });
  assert.deepEqual(lines[MAX_LINES - 1], { kind: "prompt", text: `Prompt ${MAX_LINES - 1}` });
});

test("the digest stops at MAX_DIGEST_CHARS, a whole line at a time", () => {
  const line = { kind: "prompt", text: "x".repeat(990) };
  const lines = cap(Array.from({ length: 200 }, () => line));
  assert.equal(lines.length, Math.floor(MAX_DIGEST_CHARS / (line.kind.length + 2 + line.text.length + 1)));
  assert.ok(lines.length < 200);
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

test("day: windows, bad dates and offsets", () => {
  assert.deepEqual(utc("2026-10-28"), { date: "2026-10-28", start: Date.UTC(2026, 9, 28), end: Date.UTC(2026, 9, 29) });
  assert.equal(day("2026-12-31", -300).end, Date.UTC(2027, 0, 1, 5));
  assert.throws(() => day("2026-13-01", 0), /calendar date/);
  assert.throws(() => day("28-10-2026", 0), /YYYY-MM-DD/);
  assert.equal(parseOffset("-0530"), -330);
  assert.equal(parseOffset("Z"), 0);
  assert.throws(() => parseOffset("+5"), /UTC offset/);
  assert.match(today(new Date(2026, 0, 5)), /^2026-01-05$/);
  const local = day("2026-10-28");
  assert.equal(local.end - local.start > 0, true);
});

test("parseSelection takes the node's list or a list with a form", () => {
  assert.deepEqual(parseSelection(sources()).form, undefined);
  assert.deepEqual(parseSelection({ sources: sources(), form: { selected: ["git"] } }).form, { selected: ["git"] });
  assert.throws(() => parseSelection([{ id: "x" }]), /source/);
  assert.throws(() => parseSelection({ sources: sources(), form: { selected: "git" } }), /sources_form/);
  assert.throws(() => parseSelection(42), /expected/);
});

test("the extract command prints the lines the node hands its writer", async () => {
  const file = join(fx.home, "selection.json");
  writeFileSync(file, JSON.stringify({ sources: sources(), form: { selected: ["claude-code", "git"] } }));
  const run = promisify(execFile);
  const { stdout } = await run(process.execPath, [
    "bin/extract.ts",
    "--sources",
    file,
    "--date",
    "2026-10-28",
    "--offset",
    "+00:00",
    "--home",
    fx.home,
  ]);
  assert.equal(stdout, expected.join("\n") + "\n");
  await assert.rejects(run(process.execPath, ["bin/extract.ts"]), (e: { code: number; stderr: string }) => {
    assert.equal(e.code, 2);
    assert.match(e.stderr, /--sources is required/);
    return true;
  });
});

test("a command source runs its program with --since the day's start and labels each line", async () => {
  const dir = join(fx.home, "cmd");
  mkdirSync(dir, { recursive: true });
  const program = join(dir, "activity");
  writeFileSync(program, '#!/bin/sh\necho "digestif: item opened: Command sources"\necho\necho "args: $*"\n', { mode: 0o755 });
  const broken = join(dir, "broken");
  writeFileSync(broken, "#!/bin/sh\necho partial\nexit 3\n", { mode: 0o755 });
  const d = utc("2026-10-28");
  const cmd = (label: string, paths: string[]): Source => ({ id: `command-${label.toLowerCase()}`, kind: "command", label, paths, yields: [], selected: true });
  const r = await extractWithFailures([cmd("Athena", [program, "--project", "digestif"]), cmd("Broken", [broken])], d, { home: fx.home });
  assert.deepEqual(render(r.lines), ["Athena: digestif: item opened: Command sources", `Athena: args: --project digestif --since ${d.start / 1000}`]);
  assert.deepEqual(r.failures, ["Broken exited 3"]);
  assert.deepEqual(parseSelection([cmd("Athena", [program])]).sources[0]?.kind, "command");
});

test("a command source is bounded: a hung program is ended, lines are capped and clipped", async () => {
  const dir = join(fx.home, "cmd-bounds");
  mkdirSync(dir, { recursive: true });
  const slow = join(dir, "slow");
  writeFileSync(slow, "#!/bin/sh\nsleep 5\n", { mode: 0o755 });
  const r = await commandLines([slow], 0, "Slow", 300);
  assert.deepEqual(r, { ok: false, reason: "Slow: still running after 0 seconds" });
  const long = join(dir, "long");
  writeFileSync(long, `#!/bin/sh\ni=0; while [ $i -lt ${MAX_COMMAND_LINES + 50} ]; do echo "line $i ${"x".repeat(MAX_LINE_CHARS + 100)}"; i=$((i+1)); done\n`, { mode: 0o755 });
  const l = await commandLines([long], 0, "Long");
  assert.ok(l.ok);
  assert.equal(l.lines.length, MAX_COMMAND_LINES);
  assert.ok(l.lines.every((x) => x.length <= MAX_LINE_CHARS));
  assert.deepEqual(await commandLines([join(dir, "missing")], 0, "Missing"), { ok: false, reason: `Missing: spawn ${join(dir, "missing")} ENOENT` });
});
