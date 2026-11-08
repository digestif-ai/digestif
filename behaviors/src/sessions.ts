// Claude Code sessions under ~/.claude/projects: one directory per project (the project path with
// its separators turned to dashes), one JSONL transcript per session at its top level. Deeper
// transcripts (a subagent's, under a directory named after the session) are another agent's
// conversation, not the member's, and are left alone.
//
// Only four things are read from a transcript: the title Claude Code records for the session (the
// top-level aiTitle of its records, or the summary line older transcripts carry), the member's own
// prompts (entries of type "user" whose content the member typed), their timestamps, and the
// directory the session was started in (the cwd on its first records), which decides whether the
// project is a financial one and is never extracted. Assistant
// text, tool calls and tool results are never read, nor are the slash-command and system entries
// Claude Code records as the user, its compaction summaries, or prompts a program sent through the
// Agent SDK.

import { createReadStream, realpathSync } from "node:fs";
import { opendir, readdir, rm, stat, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, isAbsolute, join } from "node:path";
import { createInterface } from "node:readline";

/** A prompt the member typed, and when. */
export interface Prompt {
  text: string;
  /** Epoch milliseconds. */
  at: number;
}

export interface Session {
  file: string;
  /** The title Claude Code recorded for the session, else its first prompt's text. */
  title: string;
  /** The first prompt, when it stands as the title because the session recorded none. */
  titlePrompt?: Prompt;
  /** Every prompt of the session in transcript order. */
  prompts: Prompt[];
}

/** A line is the whole prompt, whitespace collapsed, cut at this many characters. */
export const MAX_ITEM_CHARS = 1000;

/** The promptSource values Claude Code records for a prompt the member typed, queued or accepted. */
const MEMBER_PROMPT_SOURCES = new Set(["typed", "queued", "suggestion_accepted"]);

/** The text a member typed in a "user" entry, or undefined when the entry is not that. */
export function promptText(entry: unknown): string | undefined {
  if (typeof entry !== "object" || entry === null) return undefined;
  const e = entry as Record<string, unknown>;
  if (e.type !== "user" || e.isMeta === true || e.isSidechain === true) return undefined;
  // A compaction summary is the assistant's account of the conversation so far, recorded as the
  // user. A prompt a program sent (the Agent SDK, an auto-continuation) is not the member's either:
  // when Claude Code records where a prompt came from, only the member's own kinds are read.
  if (e.isCompactSummary === true) return undefined;
  if (typeof e.promptSource === "string" && !MEMBER_PROMPT_SOURCES.has(e.promptSource)) return undefined;
  const message = e.message;
  if (typeof message !== "object" || message === null) return undefined;
  const m = message as Record<string, unknown>;
  if (m.role !== "user") return undefined;
  let text: string;
  if (typeof m.content === "string") {
    text = m.content;
  } else if (Array.isArray(m.content)) {
    // Text blocks only: a tool_result block is tool output, an image block is not text.
    const texts = m.content.flatMap((b: unknown) => {
      if (typeof b !== "object" || b === null) return [];
      const block = b as Record<string, unknown>;
      return block.type === "text" && typeof block.text === "string" ? [block.text] : [];
    });
    if (texts.length === 0) return undefined;
    text = texts.join("\n");
  } else {
    return undefined;
  }
  text = text.replace(/^(\s*\[Image #\d+\])+/, "").trim();
  // Claude Code records slash commands, their output and its own notices as the user, in angle
  // brackets (<command-name>, <local-command-stdout>, <system-reminder>) or square ones
  // ([Request interrupted by user]). None of them is something the member said.
  if (text === "" || text.startsWith("<") || /^\[Request interrupted/.test(text)) return undefined;
  return text;
}

/** The whole prompt on one line, whitespace collapsed, at most MAX_ITEM_CHARS characters. */
export function itemLine(text: string): string {
  const whole = text.replace(/\s+/g, " ").trim();
  const chars = Array.from(whole);
  return chars.length <= MAX_ITEM_CHARS ? whole : chars.slice(0, MAX_ITEM_CHARS - 1).join("") + "…";
}

function nonEmpty(v: unknown): string | undefined {
  return typeof v === "string" && v.trim() !== "" ? v.trim() : undefined;
}

/**
 * The title an entry records for its session: its own top-level aiTitle, or the summary of an
 * older transcript's summary line. A title-named field nested in a tool result or a message is that
 * thing's, not the session's, and is not read.
 */
export function recordedTitle(entry: unknown): {
  aiTitle?: string;
  summary?: string;
} {
  if (typeof entry !== "object" || entry === null) return {};
  const e = entry as Record<string, unknown>;
  const aiTitle = nonEmpty(e.aiTitle);
  const summary = e.type === "summary" ? nonEmpty(e.summary) : undefined;
  return {
    ...(aiTitle === undefined ? {} : { aiTitle }),
    ...(summary === undefined ? {} : { summary }),
  };
}

function timestamp(entry: unknown): number | undefined {
  if (typeof entry !== "object" || entry === null) return undefined;
  const t = (entry as Record<string, unknown>).timestamp;
  if (typeof t !== "string") return undefined;
  const ms = Date.parse(t);
  return Number.isNaN(ms) ? undefined : ms;
}

export interface Transcript {
  /** The first aiTitle the transcript records, else its first summary line's summary. */
  title?: string;
  prompts: Prompt[];
  /** The bytes of the file read: all of it, or its last maxBytes. */
  bytesRead: number;
  /** The bytes before the part read, left unread because the file is over maxBytes; 0 when it is not. */
  skippedBytes: number;
}

/**
 * How much of one transcript is read: its last this many bytes. A session Claude Code keeps open for
 * weeks grows to hundreds of megabytes and is modified every minute, so it is in every window; its
 * tail holds the prompts a window can contain, and reading all of it would take the night
 * (digestif#233). DIGESTIF_MAX_TRANSCRIPT_BYTES sets it.
 */
export const DEFAULT_MAX_TRANSCRIPT_BYTES = 32 * 1024 * 1024;

/** A capped transcript's title is looked for in its first this many bytes as well as its tail. */
const TITLE_HEAD_BYTES = 1024 * 1024;

/** The per-file cap: DIGESTIF_MAX_TRANSCRIPT_BYTES when it is a positive whole number, else the default. */
export function maxTranscriptBytes(env: NodeJS.ProcessEnv = process.env): number {
  const v = env["DIGESTIF_MAX_TRANSCRIPT_BYTES"];
  const n = v === undefined || !/^\d+$/.test(v.trim()) ? NaN : Number(v.trim());
  return Number.isSafeInteger(n) && n > 0 ? n : DEFAULT_MAX_TRANSCRIPT_BYTES;
}

/** What a reading spends: it stops once `spent` answers true. */
export interface Budget {
  spent(): boolean;
}

/** A reading ran out of its budget in the middle of `file`. */
export class ReadingOverran extends Error {
  readonly file: string;
  constructor(file: string) {
    super(`ran out of time reading ${file}`);
    this.file = file;
  }
}

export interface TranscriptOptions {
  /** Only the file's last this many bytes are read. Defaults to maxTranscriptBytes(). */
  maxBytes?: number;
  /** Checked on every line: once spent, the read stops with ReadingOverran. */
  budget?: Budget;
  /** Called as bytes are read, with the total so far. */
  onBytes?: (bytesRead: number) => void;
}

// A line that names none of these cannot be a prompt or a title, and is not parsed: most of a long
// session's bytes are tool results and assistant text, and JSON.parse is most of a read's time.
const mayMatter = (line: string): boolean => line.includes('"user"') || line.includes('"aiTitle"') || line.includes('"summary"');

/**
 * Streams the lines of `file` from byte `start` (to `end`, inclusive, when given), dropping the
 * first line when the start is not the file's own: it is the end of a line begun before it.
 */
async function* linesOf(file: string, start: number, options: { end?: number; budget?: Budget; onBytes?: (n: number) => void }): AsyncGenerator<string> {
  const input = createReadStream(file, { encoding: "utf8", start, ...(options.end === undefined ? {} : { end: options.end }) });
  let bytes = 0;
  if (options.onBytes !== undefined) {
    const onBytes = options.onBytes;
    input.on("data", (chunk) => {
      bytes += Buffer.byteLength(chunk);
      onBytes(bytes);
    });
  }
  const lines = createInterface({ input, crlfDelay: Infinity });
  let first = start > 0;
  try {
    for await (const line of lines) {
      if (options.budget?.spent() === true) throw new ReadingOverran(file);
      if (first) {
        first = false;
        continue;
      }
      yield line;
    }
  } finally {
    lines.close();
    input.destroy();
  }
}

function entryOf(line: string): unknown {
  if (!line.startsWith("{") || !mayMatter(line)) return undefined;
  try {
    return JSON.parse(line);
  } catch {
    return undefined;
  }
}

/**
 * The recorded title and the member's prompts of one transcript, read line by line. A file over
 * `maxBytes` is read from the tail: its last `maxBytes` bytes, the prompts nearest the window's end,
 * and its first megabyte for the title it recorded when it began. Lines that are not JSON objects
 * are skipped.
 */
export async function readTranscript(file: string, options: TranscriptOptions = {}): Promise<Transcript> {
  const maxBytes = options.maxBytes ?? maxTranscriptBytes();
  const size = (await stat(file)).size;
  const start = size > maxBytes ? size - maxBytes : 0;
  const prompts: Prompt[] = [];
  let aiTitle: string | undefined;
  let summary: string | undefined;
  const title = (entry: unknown): void => {
    const recorded = recordedTitle(entry);
    aiTitle ??= recorded.aiTitle;
    summary ??= recorded.summary;
  };
  let headBytes = 0;
  if (start > 0) {
    const end = Math.min(TITLE_HEAD_BYTES, start) - 1;
    for await (const line of linesOf(file, 0, { end, ...(options.budget === undefined ? {} : { budget: options.budget }) })) {
      title(entryOf(line));
      if (aiTitle !== undefined) break;
    }
    headBytes = end + 1;
  }
  let bytesRead = 0;
  const onBytes = (n: number): void => {
    bytesRead = n;
    options.onBytes?.(headBytes + n);
  };
  // From the byte before the tail, so a tail that begins on a line's first byte keeps that line.
  for await (const line of linesOf(file, start > 0 ? start - 1 : 0, { onBytes, ...(options.budget === undefined ? {} : { budget: options.budget }) })) {
    const entry = entryOf(line);
    if (entry === undefined) continue;
    title(entry);
    const text = promptText(entry);
    const at = timestamp(entry);
    if (text !== undefined && at !== undefined) prompts.push({ text, at });
  }
  const t = aiTitle ?? summary;
  const counts = { bytesRead, skippedBytes: start };
  return t === undefined ? { prompts, ...counts } : { title: t, prompts, ...counts };
}

async function isDir(p: string): Promise<boolean> {
  try {
    return (await stat(p)).isDirectory();
  } catch {
    return false;
  }
}

async function jsonlFiles(dir: string): Promise<string[]> {
  let names: string[];
  try {
    names = await readdir(dir);
  } catch {
    return [];
  }
  return names
    .filter((n) => !n.startsWith(".") && n.endsWith(".jsonl"))
    .sort()
    .map((n) => join(dir, n));
}

async function exists(p: string): Promise<boolean> {
  try {
    await stat(p);
    return true;
  } catch {
    return false;
  }
}

async function names(dir: string): Promise<string[]> {
  try {
    return await readdir(dir);
  } catch {
    return [];
  }
}

/**
 * A folder judged for books is listed to at most this many entries; one with more cannot be judged,
 * so the project it encloses is skipped for the run, unjudged (DIG-295). The nightly once sat for
 * its whole deadline listing a temp folder of millions of directories.
 */
export const MAX_JUDGED_ENTRIES = 10_000;

/**
 * A folder of a project's paths had more entries than the cap, so the project cannot be judged: the
 * financial-records skip fails closed, and the project is not read this run (DIG-295).
 */
export class JudgingCapped extends Error {
  /** The folder with too many entries. */
  readonly folder: string;
  readonly max: number;
  constructor(folder: string, max: number) {
    super(`${folder} has more than ${max} entries`);
    this.folder = folder;
    this.max = max;
  }
}

/** A judgement of one project that takes longer than this many milliseconds is reported (DIG-295). */
export const SLOW_JUDGEMENT_MS = 2_000;

/**
 * The entries of a folder for judging, read one by one: JudgingCapped when it has more than the cap
 * (the rest are not read), and an empty list when it cannot be listed (DIG-295). No explicit close:
 * an opendir that fails leaves no handle, and `for await` closes the directory when the loop
 * returns early or an iteration throws.
 */
async function judgedNames(dir: string, j: Judging): Promise<string[]> {
  const found: string[] = [];
  try {
    for await (const e of await opendir(dir)) {
      if (found.length >= j.maxEntries) throw new JudgingCapped(dir, j.maxEntries);
      found.push(e.name);
    }
  } catch (e) {
    if (e instanceof JudgingCapped) throw e;
    return [];
  }
  return found;
}

/**
 * The folders the system keeps its temporary files in. A project started inside one is judged by
 * itself and its repository only, and the folders enclosing it are never listed (DIG-295).
 */
export function systemTempRoots(): string[] {
  const roots = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders", "/var/tmp", "/private/var/tmp"];
  const t = tmpdir();
  roots.push(t);
  try {
    roots.push(realpathSync(t));
  } catch {
    // A temp folder that cannot be resolved is judged as it is named.
  }
  return [...new Set(roots.map((r) => (r.length > 1 ? r.replace(/\/+$/, "") : r)).filter((r) => r.length > 1))];
}

const underAny = (path: string, roots: string[]): boolean => roots.some((r) => path === r || path.startsWith(r + "/"));

/**
 * Claude Code names a project's directory after the project's path, every UTF-16 code unit but an
 * ASCII letter or digit turned to '-' (node/web/sources.ml, encode_segment). That loses which dash was a '/', so a name is decoded against the file
 * system: from the root, each child directory whose encoded name begins the rest of the name is
 * tried in turn. Only paths that exist come back (node/web/sources.ml, decode_project_dir).
 */
async function decodeProjectDir(root: string, name: string, j: Judging): Promise<string[]> {
  const go = async (dir: string, rest: string): Promise<string[]> => {
    checkBudget(j);
    const found: string[] = [];
    // A level with more entries than the cap cannot be decoded, and the project is not judged (DIG-295).
    for (const child of await judgedNames(dir, j)) {
      const encoded = child.replace(/[^a-zA-Z0-9]/g, "-");
      if (encoded === "" || !rest.startsWith(encoded)) continue;
      const path = join(dir, child);
      if (!(await isDir(path))) continue;
      if (rest === encoded) found.push(path);
      else if (rest[encoded.length] === "-") found.push(...(await go(path, rest.slice(encoded.length + 1))));
    }
    return found;
  };
  return name.length > 1 && name.startsWith("-") ? go(root, name.slice(1)) : [];
}

/** The file kinds of personal finance and accounting (node/web/sources.ml, financial_record_suffixes). */
const FINANCIAL_RECORD_SUFFIXES = [
  ".beancount",
  ".bean",
  ".ledger",
  ".hledger",
  ".ofx",
  ".qfx",
  ".qif",
  ".qbo",
  ".gnucash",
  ".kmy",
  ".qdf",
  ".qbw",
  ".mny",
];

const isFinancialFile = (n: string) => FINANCIAL_RECORD_SUFFIXES.some((s) => n.toLowerCase().endsWith(s));

/** Whether a directory holds financial records at its top level or one level below (node/web/sources.ml, holds_financial_records). */
async function holdsFinancialRecords(dir: string, j: Judging): Promise<boolean> {
  const top = (await judgedNames(dir, j)).filter((n) => !n.startsWith("."));
  if (top.some(isFinancialFile)) return true;
  let seen = 0;
  for (const n of top) {
    if (seen++ % 100 === 0) checkBudget(j);
    const below = await judgedNames(join(dir, n), j);
    if (below.some((c) => !c.startsWith(".") && isFinancialFile(c))) return true;
  }
  return false;
}

/**
 * The directory a transcript was started in: the cwd on its first record that carries one, read
 * from its first lines only (node/web/sources.ml, transcript_cwd).
 */
async function transcriptCwd(file: string): Promise<string | undefined> {
  const lines = createInterface({ input: createReadStream(file, { encoding: "utf8" }), crlfDelay: Infinity });
  let n = 0;
  try {
    for await (const line of lines) {
      if (++n > 50) break;
      let entry: unknown;
      try {
        entry = JSON.parse(line);
      } catch {
        continue;
      }
      if (typeof entry !== "object" || entry === null || Array.isArray(entry)) continue;
      const cwd = (entry as Record<string, unknown>).cwd;
      if (typeof cwd === "string" && isAbsolute(cwd)) return cwd;
    }
  } catch {
    return undefined;
  } finally {
    lines.close();
  }
  return undefined;
}

/** Words that make a folder's name read as finance (node/web/sources.ml, finance_words). */
const FINANCE_WORDS = new Set([
  "accounting",
  "accounts",
  "bank",
  "banking",
  "beancount",
  "bookkeeping",
  "books",
  "budget",
  "budgets",
  "finance",
  "finances",
  "financial",
  "gnucash",
  "hledger",
  "ledger",
  "ledgers",
  "money",
  "quicken",
  "quickbooks",
  "tax",
  "taxes",
]);

/** Whether a folder's name, its runs of ASCII letters and digits case aside, reads as finance (node/web/sources.ml, reads_as_finance). */
function readsAsFinance(name: string): boolean {
  return name
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .some((w) => FINANCE_WORDS.has(w));
}

/** What judging one project's paths shares: the verdicts already read, the budget, and where it stops. */
interface Judging {
  memo: Map<string, Promise<boolean>>;
  budget: Budget | undefined;
  tempRoots: string[];
  /** A folder listed to more entries than this cannot be judged (JudgingCapped). */
  maxEntries: number;
  /** The project directory being judged, named by a reading that overruns. */
  project: string;
}

const checkBudget = (j: Judging): void => {
  if (j.budget?.spent() === true) throw new ReadingOverran(j.project);
};

/**
 * Whether a folder holds financial records in a subfolder of its own that is not a git repository,
 * read once per folder per listing through the memo (node/web/sources.ml, books_one_level_down). A
 * folder or child with more than the cap's entries ends the judging (JudgingCapped), and the budget
 * is checked every hundred children (DIG-295).
 */
function booksOneLevelDown(dir: string, j: Judging): Promise<boolean> {
  let v = j.memo.get(dir);
  if (v === undefined) {
    v = (async () => {
      let seen = 0;
      for (const n of (await judgedNames(dir, j)).filter((n) => !n.startsWith(".")).sort()) {
        if (seen++ % 100 === 0) checkBudget(j);
        const d = join(dir, n);
        if (await exists(join(d, ".git"))) continue;
        if ((await judgedNames(d, j)).some((c) => !c.startsWith(".") && isFinancialFile(c))) return true;
      }
      return false;
    })();
    j.memo.set(dir, v);
  }
  return v;
}

/**
 * Whether a project's path can be seen to hold financial records: itself or the repository around
 * it, or a folder enclosing it, strictly below `home` (the root outside home). Each enclosing folder
 * is tested at its top level, and one outside the repository around the path one level down as
 * well, one directly under home only when its name reads as finance. A path that no longer exists
 * is judged by the folders around it that still do (node/web/sources.ml, financial_path). A path
 * under a system temp root is judged by itself and its repository only, and the walk never lists a
 * temp root or a folder above one (DIG-295).
 */
async function financialPath(path: string, home: string, j: Judging): Promise<boolean> {
  const boundary = home.length > 1 && path.startsWith(home + "/") ? home : "/";
  // A project named for a temp root itself is judged as holding none, without listing the root.
  if (j.tempRoots.includes(path)) return false;
  if ((await isDir(path)) && (await holdsFinancialRecords(path, j))) return true;
  let repo: string | undefined;
  for (let d = path; ; d = dirname(d)) {
    if (await exists(join(d, ".git"))) {
      repo = d;
      if (await holdsFinancialRecords(d, j)) return true;
      break;
    }
    if (dirname(d) === d) break;
  }
  if (underAny(path, j.tempRoots)) return false;
  const inRepo = (d: string) => repo !== undefined && (d === repo || d.startsWith(repo + "/"));
  // The walk starts outside every temp root (a path under one returned above), and an ancestor of a
  // path outside a root cannot be inside one, so the roots need no check here.
  for (let up = dirname(path), d = path; up !== d && up !== boundary; d = up, up = dirname(up)) {
    // The enclosing walk lists each folder up to the cap but has no cap of its own on how many it visits.
    checkBudget(j);
    if ((await judgedNames(up, j)).some((n) => !n.startsWith(".") && isFinancialFile(n))) return true;
    if (inRepo(up)) continue;
    if (dirname(up) === boundary && !readsAsFinance(basename(up))) continue;
    if (await booksOneLevelDown(up, j)) return true;
  }
  return false;
}

/**
 * The verdict a project directory's last reading left: a file of this name inside the project
 * directory, beside its transcripts, written when a path of the project was seen to hold financial
 * records. Both readers of the projects directory read and write it (node/web/sources.ml,
 * financial_mark), so a project whose books were removed or moved since keeps being skipped by
 * either. It holds one line saying so and nothing of the project's.
 */
export const FINANCIAL_MARK = ".digestif-financial";

async function rememberFinancial(dir: string): Promise<void> {
  const mark = join(dir, FINANCIAL_MARK);
  if (await exists(mark)) return;
  try {
    await writeFile(mark, "Digestif: this project held financial records when last seen, so its sessions are not read.\n");
  } catch {
    return;
  }
}

async function forgetFinancial(dir: string): Promise<void> {
  await rm(join(dir, FINANCIAL_MARK), { force: true }).catch(() => undefined);
}

/**
 * Whether the project directory `dir` holds a session of a financial project: any path its name can
 * decode to, or any directory its transcripts were started in, can be seen to hold financial
 * records, or its last reading found that (FINANCIAL_MARK) and one of those paths is gone, or none is
 * left to look at. A financial verdict is remembered; a project whose every path is there and holds
 * none is read, and forgets it (node/web/sources.ml, financial_project).
 */
async function financialProject(
  root: string,
  dir: string,
  transcripts: string[],
  home: string,
  j: Judging,
): Promise<boolean> {
  const paths = new Set(await decodeProjectDir(root, basename(dir), j));
  for (const t of transcripts) {
    const cwd = await transcriptCwd(t);
    if (cwd !== undefined) paths.add(cwd);
  }
  if (await anyFinancialPath(paths, home, j)) {
    await rememberFinancial(dir);
    return true;
  }
  if (!(await exists(join(dir, FINANCIAL_MARK)))) return false;
  if (paths.size === 0) return true;
  for (const path of paths) if (!(await isDir(path))) return true;
  await forgetFinancial(dir);
  return false;
}

/**
 * A project directory with no transcript in the window is not read, but its verdict is recorded
 * while its path can still be seen, judged by the paths its name decodes to; a verdict is only ever
 * set here (node/web/sources.ml, note_financial).
 */
async function noteFinancial(root: string, dir: string, home: string, j: Judging): Promise<void> {
  if (await exists(join(dir, FINANCIAL_MARK))) return;
  if (await anyFinancialPath(await decodeProjectDir(root, basename(dir), j), home, j)) await rememberFinancial(dir);
}

/**
 * Whether any of a project's paths can be seen to hold financial records. A path whose judging is
 * capped does not end the look: the other paths are still judged, so books seen on one of them are
 * remembered, and the cap is thrown only when none held any (DIG-295).
 */
async function anyFinancialPath(paths: Iterable<string>, home: string, j: Judging): Promise<boolean> {
  let capped: JudgingCapped | undefined;
  for (const path of paths) {
    try {
      if (await financialPath(path, home, j)) return true;
    } catch (e) {
      if (!(e instanceof JudgingCapped)) throw e;
      capped ??= e;
    }
  }
  if (capped !== undefined) throw capped;
  return false;
}

async function modifiedSince(files: string[], since: number): Promise<string[]> {
  const recent: string[] = [];
  for (const f of files) {
    try {
      if ((await stat(f)).mtimeMs >= since) recent.push(f);
    } catch {
      continue;
    }
  }
  return recent;
}

export interface JudgingOptions {
  /** The system temp roots no judging lists or walks above; defaults to systemTempRoots(). */
  tempRoots?: string[];
  /** Told of a project whose judging took longer than slowJudgementMs, with the time it took. */
  onSlowJudgement?: (dir: string, ms: number) => void;
  /** Told of a project with transcripts in the window skipped unjudged, with the folder of its paths that has more entries than the cap. */
  onCappedJudgement?: (dir: string, folder: string, max: number) => void;
  /** Defaults to SLOW_JUDGEMENT_MS. */
  slowJudgementMs?: number;
  /** The clock timing a judgement, epoch milliseconds. */
  clock?: () => number;
  /** A folder listed to more entries than this cannot be judged; defaults to MAX_JUDGED_ENTRIES. */
  maxJudgedEntries?: number;
}

/**
 * The transcripts under a chosen path: the path's own top-level `.jsonl` files when it is a project
 * directory, chosen by the member whatever it holds, else those of each project directory one level
 * below it (`~/.claude/projects`) that is not a financial project. Only a transcript modified since
 * `since` (epoch milliseconds) is listed, and a project is judged by those alone; one with none has
 * its verdict recorded (noteFinancial). A project whose judging gives up on a folder past the cap is
 * skipped unjudged for this run, with no verdict recorded (JudgingCapped, DIG-295). `root` is where a
 * project's name is decoded from.
 */
export async function sessionFiles(
  path: string,
  root = "/",
  since = 0,
  home = homedir(),
  budget?: Budget,
  options: JudgingOptions = {},
): Promise<string[]> {
  if (!(await isDir(path))) return [];
  const own = await jsonlFiles(path);
  if (own.length > 0) return modifiedSince(own, since);
  const files: string[] = [];
  const memo = new Map<string, Promise<boolean>>();
  const tempRoots = options.tempRoots ?? systemTempRoots();
  const maxEntries = options.maxJudgedEntries ?? MAX_JUDGED_ENTRIES;
  const clock = options.clock ?? Date.now;
  const slowMs = options.slowJudgementMs ?? SLOW_JUDGEMENT_MS;
  for (const n of (await names(path)).filter((n) => !n.startsWith(".")).sort()) {
    const sub = join(path, n);
    // Judging a project reads the file system around its paths; a budget spent doing that names the project.
    if (budget?.spent() === true) throw new ReadingOverran(sub);
    if (!(await isDir(sub))) continue;
    const recent = await modifiedSince(await jsonlFiles(sub), since);
    const j: Judging = { memo, budget, tempRoots, maxEntries, project: sub };
    const began = clock();
    let financial = false;
    try {
      if (recent.length === 0) await noteFinancial(root, sub, home, j);
      else financial = await financialProject(root, sub, recent, home, j);
    } catch (e) {
      if (!(e instanceof JudgingCapped)) throw e;
      // Past the cap the skip fails closed: nothing of the project is read, and no verdict is kept.
      // A project with nothing in the window would not have been read anyway, so it is not reported.
      if (recent.length > 0) options.onCappedJudgement?.(sub, e.folder, e.max);
      financial = true;
    }
    const took = clock() - began;
    if (took > slowMs) options.onSlowJudgement?.(sub, took);
    if (recent.length > 0 && !financial) files.push(...recent);
  }
  return files;
}

/** How the reading of one source's sessions is going, after each transcript and as its bytes come in. */
export interface ReadingProgress {
  file: string;
  /** Bytes read of this file so far. */
  bytes: number;
  /** Milliseconds since this source's reading began. */
  elapsedMs: number;
}

export interface SessionsOptions {
  /** Each transcript's cap; defaults to maxTranscriptBytes(). */
  maxBytes?: number;
  /** Checked on every line read: once spent, the reading stops with ReadingOverran naming the file. */
  budget?: Budget;
  onProgress?: (p: ReadingProgress) => void;
  /** Told of every transcript read from its tail, and how much of it was left unread. */
  log?: (line: string) => void;
  /** The clock for elapsedMs and for timing judgements, epoch milliseconds. */
  clock?: () => number;
  /** Told of a project whose judging took over two seconds; defaults to a line through `log`, else on stderr (DIG-295). */
  onSlowJudgement?: (dir: string, ms: number) => void;
  /** Told of a project skipped unjudged past the listing cap; defaults to a line through `log`, else on stderr (DIG-295). */
  onCappedJudgement?: (dir: string, folder: string, max: number) => void;
}

const megabytes = (n: number): string => `${Math.round(n / (1024 * 1024))} MB`;

/**
 * The sessions under a path with at least one prompt after `since` (epoch milliseconds) and at or
 * before `until`. A transcript not modified since `since` cannot hold one and is not read (the
 * node filters by mtime the same way); one over the cap is read from its tail (readTranscript).
 */
export async function sessionsSince(path: string, since: number, until = Infinity, options: SessionsOptions = {}): Promise<Session[]> {
  const clock = options.clock ?? Date.now;
  const began = clock();
  const sessions: Session[] = [];
  const tell = (line: string): void => {
    if (options.log) options.log(line);
    else console.error(`digestif: ${line}`);
  };
  for (const file of await sessionFiles(path, "/", since, homedir(), options.budget, {
    clock,
    onSlowJudgement: options.onSlowJudgement ?? ((dir, ms) => tell(`judging ${dir} took ${ms} ms`)),
    onCappedJudgement:
      options.onCappedJudgement ??
      ((dir, folder, max) => tell(`judging ${dir} gave up: ${folder} has more than ${max} entries, the project is not read this run`)),
  })) {
    if (options.budget?.spent() === true) throw new ReadingOverran(file);
    // Progress is reported at most once a megabyte, not on every chunk the stream hands over.
    let reported = -Infinity;
    const progress = (bytes: number): void => {
      if (bytes - reported < 1024 * 1024) return;
      reported = bytes;
      options.onProgress?.({ file, bytes, elapsedMs: clock() - began });
    };
    progress(0);
    let transcript: Transcript;
    try {
      transcript = await readTranscript(file, {
        onBytes: progress,
        ...(options.maxBytes === undefined ? {} : { maxBytes: options.maxBytes }),
        ...(options.budget === undefined ? {} : { budget: options.budget }),
      });
    } catch (e) {
      if (e instanceof ReadingOverran) throw e;
      // A transcript removed or unreadable since it was listed has nothing to read.
      continue;
    }
    const { title, prompts, skippedBytes, bytesRead } = transcript;
    if (skippedBytes > 0) options.log?.(`skipped ${megabytes(skippedBytes)} of session ${file}: read its last ${megabytes(bytesRead)}`);
    const first = prompts[0];
    if (first === undefined) continue;
    if (!prompts.some((p) => p.at > since && p.at <= until)) continue;
    sessions.push(title === undefined ? { file, title: first.text, titlePrompt: first, prompts } : { file, title, prompts });
  }
  return sessions;
}
