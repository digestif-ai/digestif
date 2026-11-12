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

import { createReadStream, realpathSync, type Stats } from "node:fs";
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
  /** The bytes read from the file's start to look for its title; 0 when the whole file was read. */
  headBytes: number;
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

/**
 * How many bytes one source's reading may take in all, across its files: once it is reached the
 * source yields the oldest sessions it has read, the note says the reading was partial, and the
 * next note reads on from where it left off (DIG-361). The budget is checked between
 * transcripts, so a reading can pass it by one transcript: at most DEFAULT_MAX_TRANSCRIPT_BYTES of
 * its tail and TITLE_HEAD_BYTES of its head, about 289 MB in all at the defaults. That is eight
 * full-size transcripts, or thousands of ordinary ones: a day of the member's own sessions fits
 * with room to spare, and it stays well inside what the reader can get through in its ten minutes
 * on a Mac under load, where reading slows to a few megabytes a second.
 */
export const DEFAULT_MAX_SOURCE_BYTES = 256 * 1024 * 1024;

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
  const counts = { bytesRead, skippedBytes: start, headBytes };
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

async function names(dir: string): Promise<string[]> {
  try {
    return await readdir(dir);
  } catch {
    return [];
  }
}

/**
 * A folder judged for books is listed to at most this many entries; one with more cannot be judged,
 * so the project it encloses is skipped for the run, unjudged (DIG-295, DIG-413). The nightly once
 * sat for its whole deadline listing a temp folder of millions of directories.
 */
export const MAX_JUDGED_ENTRIES = 10_000;

/**
 * A folder judging had to list has more entries than the cap, so the project cannot be judged: the
 * financial-records skip fails closed, and the project is not read this run (DIG-413). It names
 * only the folder, since the reading's memo shares it between the projects that reach the folder.
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

/** An error that says the path is not there, as opposed to one that says it could not be looked at. */
const isAbsent = (e: unknown): boolean => {
  const code = (e as { code?: unknown } | null)?.code;
  return code === "ENOENT" || code === "ENOTDIR";
};

/**
 * A folder or path judging had to look at could not be read (EACCES, EPERM, EIO and the like), so
 * the project cannot be judged and is skipped as a capped one is: no verdict is kept and a mark is
 * left as it is. Only ENOENT and ENOTDIR mean the path is absent (DIG-413). It extends
 * JudgingCapped so every place that carries a cap carries this too.
 */
export class JudgingFailed extends JudgingCapped {
  /** The error code, or its message when it has none. */
  readonly why: string;
  constructor(folder: string, cause: unknown) {
    super(folder, 0);
    const code = (cause as { code?: unknown } | null)?.code;
    this.why = typeof code === "string" ? code : cause instanceof Error ? cause.message : String(cause);
    this.message = `${folder} could not be read (${this.why})`;
  }
}

/**
 * One listing for judging may take at most this many milliseconds: a folder that takes longer
 * cannot be judged, as one past the cap cannot (node/web/sources.ml, max_listing_seconds). A folder
 * on a network volume or one the system is still filling can take minutes to list.
 */
export const MAX_LISTING_MS = 2_000;

/** The error code a JudgingTimedOut carries, which names its folder's reason as took too long. */
const TOO_SLOW_TO_LIST = "too slow to list";

/**
 * A folder judging had to list took longer than the per-listing limit, so the project cannot be
 * judged. It is a JudgingFailed, not a cap: a transcript's own path never stands in for it.
 */

export class JudgingTimedOut extends JudgingFailed {
  constructor(folder: string, ms: number) {
    super(folder, { code: TOO_SLOW_TO_LIST });
    this.message = `${folder} took over ${ms} ms to list`;
  }
}

/** The one of two give-ups to carry: a folder that could not be read is kept over a plain cap, so no later branch excuses it. */
const worse = (kept: JudgingCapped | undefined, e: JudgingCapped): JudgingCapped =>
  kept === undefined || (e instanceof JudgingFailed && !(kept instanceof JudgingFailed)) ? e : kept;

/** A judgement of one project that takes longer than this many milliseconds is reported (DIG-295). */
export const SLOW_JUDGEMENT_MS = 2_000;

/**
 * The entries of a folder for judging, read one by one: JudgingCapped when it has more than `max`
 * (the rest are not read) or JudgingTimedOut past the per-listing limit, an empty list when it is not there, and JudgingFailed when it cannot be read (DIG-295, DIG-413). No explicit close:
 * an opendir that fails leaves no handle, and `for await` closes the directory when the loop
 * returns early or an iteration throws.
 */
async function judgedNames(dir: string, j: Judging): Promise<string[]> {
  const found: string[] = [];
  const began = j.clock();
  try {
    for await (const e of await opendir(dir)) {
      if (found.length >= j.maxEntries) throw new JudgingCapped(dir, j.maxEntries);
      // The listing's own clock is read every hundred entries, as the node reads it.
      if (found.length % 100 === 0 && j.clock() - began > j.maxListingMs) throw new JudgingTimedOut(dir, j.maxListingMs);
      found.push(e.name);
    }
  } catch (e) {
    if (e instanceof JudgingCapped) throw e;
    if (isAbsent(e)) return [];
    throw new JudgingFailed(dir, e);
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
 * What one reading of the projects directory has learned of the file system, shared by the judging
 * of every project in it: each folder is listed, each path stat'ed and each folder's verdict reached
 * once per reading, however many projects sit beside one another (ISS-65357). A host with thousands
 * of project directories under one folder (an agent factory's ~/ai) otherwise lists that folder,
 * and tests every name in it, once per project, so the reading grows with the square of its history.
 * Nothing judging reads is written during the reading: the only file it writes is a project
 * directory's FINANCIAL_MARK, which is never read through here.
 */
interface Seen {
  /** A listing that gave up is kept as its rejection (JudgingCapped), so the next project to reach the folder gives up at once. */
  listings: Map<string, Promise<string[]>>;
  encoded: Map<string, Promise<Map<string, string[]>>>;
  /**
   * A folder past the listing cap, streamed once per reading for every name that reaches it: its
   * children by encoded name. One past MAX_STREAMED_ENTRIES is kept as its rejection, so a later
   * decoding gives up at once (DIG-413, ISS-80253).
   */
  streamed: Map<string, Promise<Map<string, string[]>>>;
  dirs: Map<string, Promise<boolean>>;
  present: Map<string, Promise<boolean>>;
  /**
   * Verdicts on one folder, keyed by the rule and the folder: books one level down, records at the
   * top. Only a real verdict is kept as a value: a folder that cannot be judged leaves a rejection
   * here, never false (DIG-413).
   */
  verdicts: Map<string, Promise<boolean>>;
}

const newSeen = (): Seen => ({ listings: new Map(), encoded: new Map(), streamed: new Map(), dirs: new Map(), present: new Map(), verdicts: new Map() });

function once<T>(m: Map<string, Promise<T>>, key: string, read: () => Promise<T>): Promise<T> {
  let v = m.get(key);
  if (v === undefined) {
    v = read();
    m.set(key, v);
  }
  return v;
}

/** judgedNames, read once per folder per reading, a cap included: it is not listed again (DIG-413). */
const listed = (dir: string, j: Judging): Promise<string[]> =>
  once(j.seen.listings, dir, () => {
    j.onListing?.(dir);
    return judgedNames(dir, j);
  });

/** A stat for judging: absent is false, and a path that cannot be looked at is JudgingFailed, not gone. */
async function judgedStat(p: string): Promise<Stats | undefined> {
  try {
    return await stat(p);
  } catch (e) {
    if (isAbsent(e)) return undefined;
    throw new JudgingFailed(p, e);
  }
}

const isJudgedDir = (p: string, j: Judging): Promise<boolean> => once(j.seen.dirs, p, async () => (await judgedStat(p))?.isDirectory() === true);

const judgedExists = (p: string, j: Judging): Promise<boolean> => once(j.seen.present, p, async () => (await judgedStat(p)) !== undefined);

/** A folder's children by their encoded names (node/web/sources.ml, all_children); JudgingCapped past the cap. */
const encodedChildren = (dir: string, j: Judging): Promise<Map<string, string[]>> =>
  once(j.seen.encoded, dir, async () => {
    const m = new Map<string, string[]>();
    for (const child of (await listed(dir, j)).slice().sort()) {
      const e = child.replace(/[^a-zA-Z0-9]/g, "-");
      if (e === "") continue;
      const same = m.get(e);
      if (same === undefined) m.set(e, [child]);
      else same.push(child);
    }
    return m;
  });

/**
 * The most entries the decoding streams from one folder past the listing cap: past this the folder
 * cannot be decoded, for every project that reaches it (DIG-413).
 */
export const MAX_STREAMED_ENTRIES = 100_000;

/** Every child of a folder past the listing cap by encoded name, streamed once per reading with the budget checked every thousand entries. */
const streamedChildren = (dir: string, j: Judging): Promise<Map<string, string[]>> =>
  once(j.seen.streamed, dir, async () => {
    j.onListing?.(dir);
    const m = new Map<string, string[]>();
    let n = 0;
    try {
      for await (const e of await opendir(dir)) {
        if (++n % 1000 === 0) checkBudget(j);
        if (n > j.maxStreamed) throw new JudgingCapped(dir, j.maxStreamed);
        const enc = e.name.replace(/[^a-zA-Z0-9]/g, "-");
        if (enc === "") continue;
        const same = m.get(enc);
        if (same === undefined) m.set(enc, [e.name]);
        else same.push(e.name);
      }
    } catch (e) {
      if (e instanceof JudgingCapped || e instanceof ReadingOverran) throw e;
      if (isAbsent(e)) return new Map<string, string[]>();
      throw new JudgingFailed(dir, e);
    }
    for (const v of m.values()) v.sort();
    return m;
  });

/**
 * The children of a folder past the listing cap whose encoded names can begin `rest`, read from its
 * one streaming: JudgingCapped when the matches themselves pass the cap (DIG-413).
 */
async function prefixChildren(dir: string, rest: string, j: Judging): Promise<Map<string, string[]>> {
  const all = await streamedChildren(dir, j);
  const m = new Map<string, string[]>();
  let matches = 0;
  // Only a prefix of the rest that ends where it does or at a '-' can be a child's encoded name.
  for (let k = 1; k <= rest.length; k++) {
    if (k < rest.length && rest[k] !== "-") continue;
    const names = all.get(rest.slice(0, k));
    if (names === undefined) continue;
    matches += names.length;
    if (matches > j.maxEntries) throw new JudgingCapped(dir, j.maxEntries);
    m.set(rest.slice(0, k), names);
  }
  return m;
}

/** Whether a folder holds a financial record at its top level, read once per folder per reading. */
const topHoldsRecords = (dir: string, j: Judging): Promise<boolean> =>
  once(j.seen.verdicts, `top:${dir}`, async () => (await listed(dir, j)).some((n) => !n.startsWith(".") && isFinancialFile(n)));

/**
 * Claude Code names a project's directory after the project's path, every UTF-16 code unit but an
 * ASCII letter or digit turned to '-' (node/web/sources.ml, encode_segment). That loses which dash was a '/', so a name is decoded against the file
 * system: from the root, each child directory whose encoded name begins the rest of the name is
 * tried in turn. Only paths that exist come back (node/web/sources.ml, decode_project_dir).
 *
 * A branch past the cap does not end the others: when another branch resolved, its paths come back
 * with the cap beside them (`capped`), since the branch given up may be the project's real path
 * and hold books the resolved ones do not (ISS-80253). A cap with nothing resolved, or a folder
 * that could not be read, is thrown.
 */
async function decodeProjectDir(root: string, name: string, j: Judging): Promise<Decoded> {
  // Decoding against the real file system never lists the system temp folder either, whatever temp
  // roots the caller chose: it can hold millions of entries (DIG-413).
  const noGo = root === "/" ? [...j.tempRoots, ...j.systemRoots] : j.tempRoots;
  let excused: JudgingCapped | undefined;
  const go = async (dir: string, rest: string): Promise<string[]> => {
    checkBudget(j);
    // A level past the listing cap is still decoded, by streaming only the children that can match.
    let byEncoded: Map<string, string[]>;
    try {
      byEncoded = await encodedChildren(dir, j);
    } catch (e) {
      // A folder that cannot be opened is not opened again to stream it.
      if (!(e instanceof JudgingCapped) || e instanceof JudgingFailed) throw e;
      byEncoded = await prefixChildren(dir, rest, j);
    }
    const found: string[] = [];
    let capped: JudgingCapped | undefined;
    // Only a prefix of the rest that ends where it does or at a '-' can be a child's encoded name.
    for (let k = 1; k <= rest.length; k++) {
      if (k < rest.length && rest[k] !== "-") continue;
      for (const child of byEncoded.get(rest.slice(0, k)) ?? []) {
        const path = join(dir, child);
        // A temp root is never listed, so no branch goes through one (DIG-413).
        if (underAny(path, noGo)) continue;
        if (!(await isJudgedDir(path, j))) continue;
        if (k === rest.length) found.push(path);
        else {
          // One branch that gives up does not end the others: its cap is thrown only when none resolved.
          try {
            found.push(...(await go(path, rest.slice(k + 1))));
          } catch (e) {
            if (!(e instanceof JudgingCapped)) throw e;
            capped = worse(capped, e);
          }
        }
      }
    }
    // A cap on one branch is carried beside a branch that resolved, but a folder that cannot be read always ends the decode.
    if (capped instanceof JudgingFailed || (found.length === 0 && capped !== undefined)) throw capped;
    if (capped !== undefined) excused = worse(excused, capped);
    return found;
  };
  const paths = name.length > 1 && name.startsWith("-") ? await go(root, name.slice(1)) : [];
  return excused === undefined ? { paths } : { paths, capped: excused };
}

/** The paths a project's name decodes to, and the cap of a branch given up beside them, if one was. */
interface Decoded {
  paths: string[];
  capped?: JudgingCapped;
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
function holdsFinancialRecords(dir: string, j: Judging): Promise<boolean> {
  return once(j.seen.verdicts, `holds:${dir}`, async () => {
    if (await topHoldsRecords(dir, j)) return true;
    let seen = 0;
    let capped: JudgingCapped | undefined;
    for (const n of (await listed(dir, j)).filter((n) => !n.startsWith("."))) {
      if (seen++ % 100 === 0) checkBudget(j);
      try {
        if (await topHoldsRecords(join(dir, n), j)) return true;
      } catch (e) {
        if (!(e instanceof JudgingCapped)) throw e;
        capped = worse(capped, e);
      }
    }
    if (capped !== undefined) throw capped;
    return false;
  });
}

/**
 * The directory a transcript was started in: the cwd on its first record that carries one, read
 * from its first lines only (node/web/sources.ml, transcript_cwd).
 */
async function transcriptCwd(file: string): Promise<string | undefined> {
  // Only the first megabyte is looked at: a session records its cwd on its first lines, and a file that
  // has none there is not read through to find one (DIG-361).
  const lines = createInterface({ input: createReadStream(file, { encoding: "utf8", end: TITLE_HEAD_BYTES - 1 }), crlfDelay: Infinity });
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
  seen: Seen;
  budget: Budget | undefined;
  tempRoots: string[];
  /** A folder listed to more entries than this cannot be judged (JudgingCapped). */
  maxEntries: number;
  /** A folder whose listing takes longer than this many milliseconds cannot be judged (JudgingTimedOut). */
  maxListingMs: number;
  /** The clock a listing is timed by, epoch milliseconds. */
  clock: () => number;
  /** The decoding streams no more entries than this from one folder past the cap. */
  maxStreamed: number;
  /** The member's home directory: a system temp root equal to it or enclosing it is no temp root. */
  home: string;
  /** The system temp roots decoding against the real root never lists, whatever `tempRoots` the caller chose. */
  systemRoots: string[];
  /** The project directory being judged, named by a reading that overruns. */
  project: string;
  onListing: ((dir: string) => void) | undefined;
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
  return once(j.seen.verdicts, `below:${dir}`, async () => {
    let seen = 0;
    let capped: JudgingCapped | undefined;
    for (const n of (await listed(dir, j)).filter((n) => !n.startsWith(".")).sort()) {
      if (seen++ % 100 === 0) checkBudget(j);
      const d = join(dir, n);
      // A child past the cap or unreadable does not hide books in a sibling: it is thrown only when none showed any (DIG-413).
      try {
        if (await judgedExists(join(d, ".git"), j)) continue;
        if (await topHoldsRecords(d, j)) return true;
      } catch (e) {
        if (!(e instanceof JudgingCapped)) throw e;
        capped = worse(capped, e);
      }
    }
    if (capped !== undefined) throw capped;
    return false;
  });
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
  if ((await isJudgedDir(path, j)) && (await holdsFinancialRecords(path, j))) return true;
  let repo: string | undefined;
  for (let d = path; ; d = dirname(d)) {
    if (await judgedExists(join(d, ".git"), j)) {
      repo = d;
      if (await holdsFinancialRecords(d, j)) return true;
      break;
    }
    if (dirname(d) === d) break;
  }
  if (underAny(path, j.tempRoots)) return false;
  const inRepo = (d: string) => repo !== undefined && (d === repo || d.startsWith(repo + "/"));
  for (let up = dirname(path), d = path; up !== d && up !== boundary; d = up, up = dirname(up)) {
    if (underAny(up, j.tempRoots)) break;
    // The enclosing walk lists each folder up to the cap but has no cap of its own on how many it visits.
    checkBudget(j);
    if (await topHoldsRecords(up, j)) return true;
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
  try {
    if ((await judgedStat(mark)) !== undefined) return;
  } catch {
    return; // A mark that cannot be looked at is not overwritten.
  }
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
  // A level of the root past the cap cannot be decoded, but the paths the transcripts name are still judged.
  let capped: JudgingCapped | undefined;
  // A branch given up beside one that resolved: the resolved paths are judged, but their holding no books is no verdict.
  let excused: JudgingCapped | undefined;
  const paths = new Set<string>();
  try {
    const decoded = await decodeProjectDir(root, basename(dir), j);
    for (const p of decoded.paths) paths.add(p);
    excused = decoded.capped;
  } catch (e) {
    if (!(e instanceof JudgingCapped)) throw e;
    capped = e;
  }
  let cwds = 0;
  for (const t of transcripts) {
    const cwd = await transcriptCwd(t);
    if (cwd !== undefined) {
      paths.add(cwd);
      cwds++;
    }
  }
  // With no transcript naming where it was started, the branch given up may be the project, so it is not judged (ISS-80253).
  if (excused !== undefined && cwds === 0) capped = excused;
  try {
    if (await anyFinancialPath(paths, home, j)) {
      await rememberFinancial(dir);
      return true;
    }
  } catch (e) {
    if (!(e instanceof JudgingCapped)) throw e;
    capped = worse(capped, e);
  }
  // No path showed books and one could not be judged: no verdict, the mark left as it is (DIG-413).
  // A mark that cannot be looked at is JudgingFailed, not no mark.
  const marked = (await judgedStat(join(dir, FINANCIAL_MARK))) !== undefined;
  if (capped !== undefined) {
    // A project the mark already skips, with a path gone, is skipped on that and not reported as capped.
    if (marked && paths.size > 0) for (const path of paths) if (!(await isJudgedDir(path, j))) return true;
    throw capped;
  }
  if (!marked) return false;
  if (paths.size === 0) return true;
  for (const path of paths) if (!(await isJudgedDir(path, j))) return true;
  // A branch given up may still hold the books the mark was written for: the mark stays, and so does the skip (ISS-80253).
  if (excused !== undefined) return true;
  await forgetFinancial(dir);
  return false;
}

/**
 * A project directory with no transcript in the window is not read, but its verdict is recorded
 * while its path can still be seen, judged by the paths its name decodes to; a verdict is only ever
 * set here (node/web/sources.ml, note_financial). A project that cannot be judged past the cap
 * throws JudgingCapped and keeps no verdict (DIG-413).
 */
async function noteFinancial(root: string, dir: string, home: string, j: Judging): Promise<void> {
  if ((await judgedStat(join(dir, FINANCIAL_MARK))) !== undefined) return;
  if (await anyFinancialPath((await decodeProjectDir(root, basename(dir), j)).paths, home, j)) await rememberFinancial(dir);
}

/**
 * Whether any of a project's paths can be seen to hold financial records. A path whose judging is
 * capped does not end the look: the other paths are still judged, so books seen on one of them are
 * a real verdict, and the cap is thrown only when none held any (DIG-413).
 */
async function anyFinancialPath(paths: Iterable<string>, home: string, j: Judging): Promise<boolean> {
  let capped: JudgingCapped | undefined;
  for (const path of paths) {
    try {
      if (await financialPath(path, home, j)) return true;
    } catch (e) {
      if (!(e instanceof JudgingCapped)) throw e;
      capped = worse(capped, e);
    }
  }
  if (capped !== undefined) throw capped;
  return false;
}

async function modifiedSinceAt(files: string[], since: number): Promise<{ file: string; at: number }[]> {
  const recent: { file: string; at: number }[] = [];
  for (const f of files) {
    try {
      const at = (await stat(f)).mtimeMs;
      if (at >= since) recent.push({ file: f, at });
    } catch {
      continue;
    }
  }
  return recent;
}

const oldestFirst = (a: { file: string; at: number }, b: { file: string; at: number }): number => a.at - b.at || (a.file < b.file ? -1 : 1);

export interface JudgingOptions {
  /** The system temp roots no judging lists or walks above; defaults to systemTempRoots(). */
  tempRoots?: string[];
  /** Told of a project whose judging took longer than slowJudgementMs, with the time it took. */
  onSlowJudgement?: (dir: string, ms: number) => void;
  /** Defaults to SLOW_JUDGEMENT_MS. */
  slowJudgementMs?: number;
  /** The clock timing a judgement, epoch milliseconds. */
  clock?: () => number;
  /** A folder listed to more entries than this cannot be judged; defaults to MAX_JUDGED_ENTRIES. */
  maxJudgedEntries?: number;
  /** The most entries the decoding streams from one folder past the cap; defaults to MAX_STREAMED_ENTRIES. For tests. */
  maxStreamedEntries?: number;
  /** A folder whose listing takes longer than this many milliseconds cannot be judged; defaults to MAX_LISTING_MS. */
  maxListingMs?: number;
  /**
   * The system temp roots decoding against the real root never lists; defaults to
   * systemTempRoots(). For tests whose fixtures sit under the system temp folder.
   */
  systemTempRoots?: string[];
  /**
   * Told of a project with transcripts in the window skipped unjudged, with the folder of its paths
   * that has more entries than the cap. A folder is told of once per reading, with the first project
   * that reached it, though every project that reaches it is skipped (DIG-413).
   */
  onCappedJudgement?: (dir: string, folder: string, max: number) => void;
  /** Told, once per folder per reading, of a project skipped because a folder or path could not be read, and the error code. */
  onUnreadableJudgement?: (dir: string, folder: string, why: string) => void;
  /** Told of each folder judging lists, as it lists it. */
  onListing?: (dir: string) => void;
  /**
   * Answer the transcripts oldest first, not by path: a reading that may stop early reads the
   * oldest, so the next one can read on from where it stopped.
   */
  oldestFirst?: boolean;
  /** Project directories whose names start with these roots' encoded paths are the factory's, not the member's. */
  factoryRoots?: string[];
  /** Told of a project skipped before any of it was read, why, and how many transcripts of the window it held. */
  onSkipped?: (dir: string, reason: SkipReason, transcripts: number) => void;
  /** Told of each project as judging begins on it. */
  onProject?: (dir: string) => void;
}

/** Why a project's transcripts were skipped without being read: not the member's, or unjudged past the listing cap, an unreadable folder or a slow listing (DIG-413). */
export type SkipReason = "factory" | "temp" | "capped" | "unreadable" | "slow";

/** The Dev Factory's own directories under `home`, whose projects are never the member's (DIG-361). */
export const factoryRoots = (home: string): string[] => [join(home, ".devfactory")];

const encodedPath = (p: string): string => p.replace(/[^a-zA-Z0-9]/g, "-");

/** Whether an encoded project name is the encoded path `e` or a path under it. */
const namesUnder = (name: string, e: string): boolean => name === e || name.startsWith(e + "-");

/** A root a project is skipped under, and the encoded paths of its siblings whose names start with its own. */
export interface SkipRoot {
  reason: SkipReason;
  encoded: string;
  rivals: string[];
}

/**
 * The roots projects are skipped under, each with its look-alike siblings: the folders beside the
 * root whose encoded paths begin with the root's own (~/.devfactory-notes beside ~/.devfactory,
 * /tmp-scratch beside /tmp). A root that is the home directory or encloses it is no root at all:
 * every project would be under it (a TMPDIR set to the home directory).
 */
export async function skipRoots(o: { factoryRoots: string[]; tempRoots: string[]; home: string }): Promise<SkipRoot[]> {
  const out: SkipRoot[] = [];
  for (const [reason, roots] of [["factory", o.factoryRoots], ["temp", o.tempRoots]] as const) {
    for (const raw of roots) {
      const root = raw.length > 1 ? raw.replace(/\/+$/, "") : raw;
      if (root.length <= 1 || o.home === root || o.home.startsWith(root + "/")) continue;
      const encoded = encodedPath(root);
      const parent = dirname(root);
      let siblings: string[] = [];
      try {
        siblings = await readdir(parent);
      } catch {
        // A parent that cannot be listed shows no look-alikes.
      }
      const rivals = siblings
        .map((n) => encodedPath(join(parent, n)))
        .filter((e) => e !== encoded && e.length > encoded.length && namesUnder(e, encoded));
      out.push({ reason, encoded, rivals });
    }
  }
  return out;
}

/**
 * Whether a project is not the member's, decided by its directory's name alone: it is under the Dev
 * Factory's own directory (its run work trees, draft triage, versions and the rest) or under a temp
 * root (DIG-361). The encoded name cannot tell /tmp/x from /tmp-x by itself, so a name that also
 * reads as a path under a folder beside the root whose name starts with the root's
 * (~/.devfactory-notes, /tmp-scratch) is that folder's and is read. Nothing under a skipped root is
 * ever opened, not even to find its cwd. The Rules deny list has no path roots, so no project is
 * skipped for what it is called.
 */
function skipReason(name: string, roots: SkipRoot[]): SkipReason | undefined {
  for (const r of roots) {
    if (namesUnder(name, r.encoded) && !r.rivals.some((e) => namesUnder(name, e))) return r.reason;
  }
  return undefined;
}

/**
 * The transcripts under a chosen path: the path's own top-level `.jsonl` files when it is a project
 * directory, chosen by the member whatever it holds, else those of each project directory one level
 * below it (`~/.claude/projects`) that is not a financial project. Only a transcript modified since
 * `since` (epoch milliseconds) is listed, and a project is judged by those alone; one with none has
 * its verdict recorded (noteFinancial). A project whose judging gives up on a folder past the cap is
 * skipped unjudged for this run, with no verdict recorded and an existing one left alone
 * (JudgingCapped, DIG-413). `root` is where a project's name is decoded from.
 */
export async function sessionFiles(
  path: string,
  root = "/",
  since = 0,
  home = homedir(),
  budget?: Budget,
  options: JudgingOptions = {},
): Promise<string[]> {
  return (await sessionFilesAt(path, root, since, home, budget, options)).map((f) => f.file);
}

/**
 * What one reading keeps across every path it reads: the file system it has seen, the folders it
 * has told of, and the system temp roots, worked out once (ISS-80253).
 */
interface Reading {
  seen: Seen;
  toldOf: Set<string>;
  systemRoots: string[];
}

const newReading = (): Reading => ({ seen: newSeen(), toldOf: new Set(), systemRoots: systemTempRoots() });

/** sessionFiles, each transcript with its modification time. */
async function sessionFilesAt(
  path: string,
  root: string,
  since: number,
  home: string,
  budget: Budget | undefined,
  options: JudgingOptions,
  reading: Reading = newReading(),
): Promise<{ file: string; at: number }[]> {
  const order = (fs: { file: string; at: number }[]): { file: string; at: number }[] =>
    options.oldestFirst === true ? fs.sort(oldestFirst) : fs.sort((a, b) => (a.file < b.file ? -1 : a.file > b.file ? 1 : 0));
  if (!(await isDir(path))) return [];
  const own = await jsonlFiles(path);
  if (own.length > 0) return options.oldestFirst === true ? order(await modifiedSinceAt(own, since)) : modifiedSinceAt(own, since);
  const found: { file: string; at: number }[] = [];
  const { seen, toldOf } = reading;
  // A temp root that is the home directory or encloses it is no root at all, as in skipRoots.
  const notHome = (roots: string[]): string[] => roots.filter((r) => home !== r && !home.startsWith(r + "/"));
  const tempRoots = notHome(options.tempRoots ?? reading.systemRoots);
  const systemRoots = notHome(options.systemTempRoots ?? reading.systemRoots);
  const maxEntries = options.maxJudgedEntries ?? MAX_JUDGED_ENTRIES;
  const clock = options.clock ?? Date.now;
  const slowMs = options.slowJudgementMs ?? SLOW_JUDGEMENT_MS;
  const skipping = await skipRoots({ factoryRoots: options.factoryRoots ?? [], tempRoots, home });
  // Each project's window is read first, and a project that is not the member's is skipped before
  // judging it or reading a transcript of it. The rest are judged newest first, so a budget that
  // runs out leaves the oldest unjudged.
  const active: { sub: string; recent: { file: string; at: number }[] }[] = [];
  const idle: string[] = [];
  for (const n of (await names(path)).filter((n) => !n.startsWith(".")).sort()) {
    const sub = join(path, n);
    if (budget?.spent() === true) throw new ReadingOverran(sub);
    if (!(await isDir(sub))) continue;
    const recent = await modifiedSinceAt(await jsonlFiles(sub), since);
    const reason = skipReason(n, skipping);
    if (reason !== undefined) {
      options.onSkipped?.(sub, reason, recent.length);
      continue;
    }
    if (recent.length === 0) idle.push(sub);
    else active.push({ sub, recent });
  }
  const newest = (r: { recent: { at: number }[] }): number => Math.max(...r.recent.map((x) => x.at));
  active.sort((a, b) => newest(b) - newest(a) || (a.sub < b.sub ? -1 : 1));
  const judging = (sub: string): Judging => ({
    seen,
    budget,
    tempRoots,
    maxEntries,
    maxStreamed: options.maxStreamedEntries ?? MAX_STREAMED_ENTRIES,
    maxListingMs: options.maxListingMs ?? MAX_LISTING_MS,
    clock,
    home,
    systemRoots,
    project: sub,
    onListing: options.onListing,
  });
  for (const { sub, recent } of active) {
    // Judging a project reads the file system around its paths; a budget spent doing that names the project.
    if (budget?.spent() === true) throw new ReadingOverran(sub);
    options.onProject?.(sub);
    const began = clock();
    let financial: boolean;
    try {
      financial = await financialProject(root, sub, recent.map((r) => r.file), home, judging(sub));
    } catch (e) {
      if (!(e instanceof JudgingCapped)) throw e;
      // Past the cap the skip fails closed: nothing of the project is read, and no verdict is kept.
      options.onSkipped?.(sub, e instanceof JudgingTimedOut ? "slow" : e instanceof JudgingFailed ? "unreadable" : "capped", recent.length);
      if (!toldOf.has(e.folder)) {
        toldOf.add(e.folder);
        if (e instanceof JudgingFailed) options.onUnreadableJudgement?.(sub, e.folder, e.why);
        else options.onCappedJudgement?.(sub, e.folder, e.max);
      }
      financial = true;
    }
    const took = clock() - began;
    if (took > slowMs) options.onSlowJudgement?.(sub, took);
    if (!financial) found.push(...recent);
  }
  for (const sub of idle) {
    if (budget?.spent() === true) throw new ReadingOverran(sub);
    const began = clock();
    try {
      await noteFinancial(root, sub, home, judging(sub));
    } catch (e) {
      // A project with nothing in the window would not have been read anyway, so it is not reported.
      if (!(e instanceof JudgingCapped)) throw e;
    }
    const took = clock() - began;
    if (took > slowMs) options.onSlowJudgement?.(sub, took);
  }
  return order(found);
}

/** How the reading of one source's sessions is going, after each transcript and as its bytes come in. */
export interface ReadingProgress {
  file: string;
  /** Bytes read so far across all the transcripts of this source, the file being read included. */
  bytes: number;
  /** Milliseconds since this source's reading began. */
  elapsedMs: number;
}

export interface SessionsOptions {
  /** Each transcript's cap; defaults to maxTranscriptBytes(). */
  maxBytes?: number;
  /** The most bytes read across all the transcripts; defaults to DEFAULT_MAX_SOURCE_BYTES. */
  maxTotalBytes?: number;
  /** Checked on every line read: once spent, the reading stops with the sessions read so far (ReadingOverran when none was). */
  budget?: Budget;
  onProgress?: (p: ReadingProgress) => void;
  /**
   * Told once when a budget ended the reading before the last transcript, which budget, and what
   * the window is read through (partialThrough), so the next reading starts there and reads what
   * this one did not.
   */
  onPartial?: (why: "time" | "bytes", through: number) => void;
  /** Told of every transcript read from its tail, and how much of it was left unread. */
  log?: (line: string) => void;
  /** The clock for elapsedMs, epoch milliseconds. */
  clock?: () => number;
  /** Told of a project whose judging took over two seconds; defaults to a line through `log`, else on stderr (DIG-295). */
  onSlowJudgement?: (dir: string, ms: number) => void;
  /** A folder listed to more entries than this cannot be judged; defaults to MAX_JUDGED_ENTRIES. */
  maxJudgedEntries?: number;
  /** Told of a project skipped unjudged past the listing cap; defaults to a line through `log`, else on stderr (DIG-413). */
  onCappedJudgement?: (dir: string, folder: string, max: number) => void;
  /** Told, once per folder per reading, of a project skipped because a folder or path could not be read, and the error code. */
  onUnreadableJudgement?: (dir: string, folder: string, why: string) => void;
  /** The home directory the Dev Factory's own directory is under; defaults to the user's. */
  home?: string;
  /** The temp roots whose projects are skipped; defaults to systemTempRoots(). */
  tempRoots?: string[];
  /** When a transcript was created, epoch milliseconds, or undefined where the file system does not record it; defaults to bornAt. */
  bornAt?: (file: string) => Promise<number | undefined>;
  /** Told once judging is over, of the projects it left unjudged and the folders why; told with none when it skipped nothing (ISS-81609). */
  onUnjudged?: (u: Unjudged) => void;
}

/**
 * How long before its file's birthtime a transcript's first prompt may be stamped: Claude Code
 * stamps a prompt as it takes it and creates the file to write it, so the two are at most moments
 * apart. ISS-74108
 */
export const BIRTH_MARGIN_MS = 5_000;

/** When a file was created, where the file system records it: a birthtime of zero, or past its mtime, is none. */
export async function bornAt(file: string): Promise<number | undefined> {
  try {
    const st = await stat(file);
    return Number.isFinite(st.birthtimeMs) && st.birthtimeMs > 0 && st.birthtimeMs <= st.mtimeMs ? st.birthtimeMs : undefined;
  } catch {
    return undefined;
  }
}

/**
 * Where a budget-cut reading's window ends: at the newest prompt it read, unless a transcript it did
 * not read was created before that, when it may hold older prompts. Each unread transcript's
 * prompts are bounded from below by its birthtime less BIRTH_MARGIN_MS, and the window ends at the
 * earliest bound, so the next reading, from there on, reads them. A bound at or before `since`
 * cannot move the window, and the reading ends at the newest prompt read so the next one goes on.
 * A transcript with no birthtime bounds nothing. ISS-74108
 */
export async function partialThrough(newestRead: number, unread: string[], since: number, born: (file: string) => Promise<number | undefined> = bornAt): Promise<number> {
  let through = newestRead;
  for (const file of unread) {
    const b = await born(file);
    if (b !== undefined) through = Math.min(through, b - BIRTH_MARGIN_MS);
  }
  return through > since ? through : newestRead;
}

const megabytes = (n: number): string => `${Math.round(n / (1024 * 1024))} MB`;

const SKIP_WORDS: Record<SkipReason, string> = {
  factory: "under the factory's directory",
  temp: "under a temp root",
  capped: "left unjudged past the listing cap",
  unreadable: "left unjudged for a folder that could not be read",
  slow: "left unjudged for a folder too slow to list",
};

/** Why a folder kept a project unjudged, as the node's notice names it (node/web/skipped.ml). */
export type UnjudgedReason = "no_access" | "too_many" | "too_long" | "could_not_read";

/**
 * The projects a reading left unjudged and so unread, and each folder that could not be judged,
 * with why. It names folders, so it goes to the node's notice on this machine and nowhere else:
 * never into the record, a note or a log line that leaves the machine (ISS-81609).
 */
export interface Unjudged {
  projects: number;
  folders: { folder: string; reason: UnjudgedReason }[];
}

/** The reason a folder that could not be judged is named by: no access for a refused open, took too long for a slow listing (JudgingTimedOut), else could not be read. */
export const unreadableReason = (why: string): UnjudgedReason =>
  why === "EACCES" || why === "EPERM" ? "no_access" : why === TOO_SLOW_TO_LIST ? "too_long" : "could_not_read";

/** The one line a reading logs for the projects it skipped unread, with why. */
export function skippedLine(counts: Record<SkipReason, number>): string | undefined {
  const total = counts.factory + counts.temp + counts.capped + counts.unreadable + counts.slow;
  if (total === 0) return undefined;
  const why = (Object.keys(SKIP_WORDS) as SkipReason[]).filter((r) => counts[r] > 0).map((r) => `${counts[r]} ${SKIP_WORDS[r]}`);
  return `skipped ${total} transcript${total === 1 ? "" : "s"} before reading, ${why.join(", ")}`;
}

/**
 * The sessions under one or more paths with at least one prompt after `since` (epoch milliseconds)
 * and at or before `until`, oldest transcript first across them all. A transcript not modified
 * since `since` cannot hold one and is not read (the node filters by mtime the same way); one over
 * the cap is read from its tail (readTranscript); one of a project that is not the member's (under
 * the factory's own directory or a temp root) is skipped by its path and never opened (DIG-361).
 *
 * When the time budget or the byte budget runs out after some sessions were yielded, the reading
 * ends with those and `onPartial` says why and where the window ends (partialThrough): at the
 * newest prompt yielded, or earlier where a transcript left unread was created before it and may
 * hold older prompts. A transcript left unread was modified after every one read, so the next
 * reading, from that end on, reads it; the prompts read past the end are left out of this one and
 * yielded by the next. When it runs out before any session was yielded, in judging or in reading,
 * it throws ReadingOverran and the source fails, so its window is read again. ISS-74092 ISS-74108
 */
export async function sessionsSince(path: string | string[], since: number, until = Infinity, options: SessionsOptions = {}): Promise<Session[]> {
  const clock = options.clock ?? Date.now;
  const home = options.home ?? homedir();
  const began = clock();
  const sessions: Session[] = [];
  const skipped: Record<SkipReason, number> = { factory: 0, temp: 0, capped: 0, unreadable: 0, slow: 0 };
  const unjudged: Unjudged = { projects: 0, folders: [] };
  let total = 0;
  const report = (file: string, bytes: number): void => void options.onProgress?.({ file, bytes: total + bytes, elapsedMs: clock() - began });
  const tell = (line: string): void => {
    if (options.log) options.log(line);
    else console.error(`digestif: ${line}`);
  };
  const judging: JudgingOptions = {
    ...(options.tempRoots === undefined ? {} : { tempRoots: options.tempRoots }),
    factoryRoots: factoryRoots(home),
    ...(options.maxJudgedEntries === undefined ? {} : { maxJudgedEntries: options.maxJudgedEntries }),
    onSkipped: (_dir, reason, n) => {
      skipped[reason] += n;
      if (reason === "capped" || reason === "unreadable" || reason === "slow") unjudged.projects += 1;
    },
    onProject: (dir) => {
      report(dir, 0);
    },
    onSlowJudgement: options.onSlowJudgement ?? ((dir, ms) => tell(`judging ${dir} took ${ms} ms`)),
    onCappedJudgement: (dir, folder, max) => {
      unjudged.folders.push({ folder, reason: "too_many" });
      if (options.onCappedJudgement) options.onCappedJudgement(dir, folder, max);
      else tell(`judging ${dir} gave up: ${folder} has more than ${max} entries, the project is not read this run`);
    },
    onUnreadableJudgement: (dir, folder, why) => {
      unjudged.folders.push({ folder, reason: unreadableReason(why) });
      if (options.onUnreadableJudgement) options.onUnreadableJudgement(dir, folder, why);
      else
        tell(
          `judging ${dir} gave up: ${folder} could not be read (${why}), the project is not read this run` +
            (why === "EPERM" ? ". On macOS this usually means the process lacks Full Disk Access to that folder" : ""),
        );
    },
  };
  const listed: { file: string; at: number }[] = [];
  // One reading across every path: a folder two paths' projects reach is listed and told of once.
  const reading = newReading();
  for (const p of typeof path === "string" ? [path] : path) listed.push(...(await sessionFilesAt(p, "/", since, home, options.budget, judging, reading)));
  const files = [...new Map(listed.map((f) => [f.file, f])).values()].sort(oldestFirst).map((f) => f.file);
  const line = skippedLine(skipped);
  if (line !== undefined) options.log?.(line);
  options.onUnjudged?.(unjudged);
  let partial: "time" | "bytes" | undefined;
  const maxTotal = options.maxTotalBytes ?? DEFAULT_MAX_SOURCE_BYTES;
  // The file a budget ran out at: with no session yielded before it, the source fails there.
  let stoppedAt = "";
  // The transcripts a cut reading left unread: the one it stopped at and every one after it.
  let unread: string[] = [];
  for (const [i, file] of files.entries()) {
    if (partial !== undefined) break;
    if (total >= maxTotal) {
      partial = "bytes";
      stoppedAt = file;
      unread = files.slice(i);
      break;
    }
    if (options.budget?.spent() === true) {
      partial = "time";
      stoppedAt = file;
      unread = files.slice(i);
      break;
    }
    // Progress is reported at most once a megabyte of a file, not on every chunk the stream hands over.
    let reported = -Infinity;
    const progress = (bytes: number): void => {
      if (bytes - reported < 1024 * 1024) return;
      reported = bytes;
      report(file, bytes);
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
      if (!(e instanceof ReadingOverran)) continue; // A transcript removed or unreadable since it was listed has nothing to read.
      partial = "time";
      stoppedAt = file;
      unread = files.slice(i);
      break;
    }
    total += transcript.bytesRead + transcript.headBytes;
    report(file, 0);
    const { title, prompts, skippedBytes, bytesRead } = transcript;
    if (skippedBytes > 0) options.log?.(`skipped ${megabytes(skippedBytes)} of session ${file}: read its last ${megabytes(bytesRead)}`);
    const first = prompts[0];
    if (first === undefined) continue;
    if (!prompts.some((p) => p.at > since && p.at <= until)) continue;
    sessions.push(title === undefined ? { file, title: first.text, titlePrompt: first, prompts } : { file, title, prompts });
  }
  if (partial !== undefined) {
    // Counted in sessions yielded, not transcripts read: transcripts with nothing in the window
    // move nothing, and a reading that yielded nothing fails rather than reading its window through.
    if (sessions.length === 0) throw new ReadingOverran(stoppedAt);
    const inWindow = sessions.flatMap((s) => s.prompts.filter((p) => p.at > since && p.at <= until).map((p) => p.at));
    const through = await partialThrough(Math.max(...inWindow), unread, since, options.bornAt);
    options.onPartial?.(partial, through);
    // A prompt after the window's end is the next reading's, so it is yielded once, by that one.
    return sessions.map((s) => ({ ...s, prompts: s.prompts.filter((p) => p.at <= through) })).filter((s) => s.prompts.some((p) => p.at > since));
  }
  return sessions;
}
