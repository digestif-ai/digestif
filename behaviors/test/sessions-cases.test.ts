// The sessions readers' shared verdict corpus (node/web/test/sessions_cases.json): every case is a
// folder layout built in a temp directory, read by sessionFiles, and its project's verdict and mark
// asserted. node/web/test runs the same file against the node's reader, so a verdict changed in one
// reader and not the corpus fails that reader's suite. Every path here is made up.
import assert from "node:assert/strict";
import { chmodSync, existsSync, symlinkSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { factoryRoots, FINANCIAL_MARK, MAX_LISTING_MS, sessionFiles, type SkipReason } from "../src/sessions.ts";

type Verdict = "read" | "financial" | "skipped" | "cannot_judge";

interface Case {
  name: string;
  temp_roots?: string[];
  dirs?: string[];
  files?: string[];
  crowded?: { dir: string; entries: number }[];
  unreadable?: string[];
  symlinks?: { path: string; to: string }[];
  slow?: string[];
  marked?: boolean;
  project: string;
  cwd: string | null;
  verdict: Verdict;
  mark: boolean;
}

const corpus = JSON.parse(readFileSync(join(import.meta.dirname, "..", "..", "node", "web", "test", "sessions_cases.json"), "utf8")) as {
  max_entries: number;
  cases: Case[];
};

const asRoot = process.getuid?.() === 0;

/** A project directory's name for a path, as Claude Code writes it. */
const encoded = (p: string) => p.replace(/[^a-zA-Z0-9]/g, "-");

/** The verdict a reading came to on the one project of a case, from what it listed and why it skipped. */
function verdictOf(listed: string[], skipped: SkipReason[]): Verdict {
  if (listed.length > 0) return "read";
  const why = skipped[0];
  if (why === "factory" || why === "temp") return "skipped";
  if (why !== undefined) return "cannot_judge";
  return "financial";
}

async function run(c: Case): Promise<{ verdict: Verdict; mark: boolean }> {
  const base = mkdtempSync(join(tmpdir(), "digestif-corpus-"));
  const at = (p: string) => (p === "." ? base : join(base, p));
  const locked = (c.unreadable ?? []).map(at);
  try {
    const home = at("h");
    mkdirSync(home, { recursive: true });
    for (const d of c.dirs ?? []) mkdirSync(at(d), { recursive: true });
    for (const f of c.files ?? []) {
      mkdirSync(dirname(at(f)), { recursive: true });
      writeFileSync(at(f), "");
    }
    for (const { dir, entries } of c.crowded ?? []) {
      mkdirSync(at(dir), { recursive: true });
      for (let i = 0; i < entries; i++) writeFileSync(join(at(dir), `e${i}.txt`), "");
    }
    for (const d of c.slow ?? []) mkdirSync(at(d), { recursive: true });
    for (const { path, to } of c.symlinks ?? []) {
      mkdirSync(dirname(at(path)), { recursive: true });
      symlinkSync(to, at(path));
    }
    const projects = join(home, ".claude", "projects");
    const dir = join(projects, encoded(at(c.project)));
    mkdirSync(dir, { recursive: true });
    const record = { type: "user", message: { role: "user", content: "A prompt" }, timestamp: new Date().toISOString(), ...(c.cwd === null ? {} : { cwd: at(c.cwd) }) };
    writeFileSync(join(dir, "s.jsonl"), JSON.stringify(record) + "\n");
    if (c.marked === true) writeFileSync(join(dir, FINANCIAL_MARK), "marked\n");
    for (const d of locked) chmodSync(d, 0o000);
    // A slow folder's listing outlasts the limit: the clock moves past it on every read while one is listed.
    const slow = new Set((c.slow ?? []).map(at));
    let now = 0;
    let listing = "";
    const skipped: SkipReason[] = [];
    const listed = await sessionFiles(projects, "/", 0, home, undefined, {
      tempRoots: (c.temp_roots ?? []).map(at),
      // The fixture sits under the system temp folder, so decoding from the real root must be let through it.
      systemTempRoots: [],
      factoryRoots: factoryRoots(home),
      maxJudgedEntries: corpus.max_entries,
      // The system temp folder is streamed on the way down, whatever its size.
      maxStreamedEntries: Number.MAX_SAFE_INTEGER,
      onListing: (d) => void (listing = d),
      clock: () => (slow.has(listing) ? (now += MAX_LISTING_MS * 5) : now),
      onSkipped: (_d, why) => void skipped.push(why),
    });
    return { verdict: verdictOf(listed, skipped), mark: existsSync(join(dir, FINANCIAL_MARK)) };
  } finally {
    for (const d of locked) chmodSync(d, 0o700);
    rmSync(base, { recursive: true, force: true });
  }
}

test("the corpus has cases", () => {
  assert.ok(corpus.cases.length >= 20);
  assert.equal(new Set(corpus.cases.map((c) => c.name)).size, corpus.cases.length, "every case has its own name");
});

for (const c of corpus.cases) {
  const skip = asRoot && (c.unreadable ?? []).length > 0 ? "root reads a folder of mode 000" : false;
  test(`sessions corpus: ${c.name}`, { skip }, async () => {
    assert.deepEqual(await run(c), { verdict: c.verdict, mark: c.mark });
  });
}
