// Claude Code sessions under ~/.claude/projects: one directory per project (the project path with
// its separators turned to dashes), one JSONL transcript per session at its top level. Deeper
// transcripts (a subagent's, under a directory named after the session) are another agent's
// conversation, not the member's, and are left alone.
//
// Only three things are read from a transcript: the title Claude Code records for the session (the
// top-level aiTitle of its records, or the summary line older transcripts carry), the member's own
// prompts (entries of type "user" whose content the member typed) and their timestamps. Assistant
// text, tool calls and tool results are never read, nor are the slash-command and system entries
// Claude Code records as the user, its compaction summaries, or prompts a program sent through the
// Agent SDK.

import { createReadStream } from "node:fs";
import { readdir, stat } from "node:fs/promises";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";
import type { Day } from "./day.ts";

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
}

/** The recorded title and the member's prompts of one transcript. Lines that are not JSON objects are skipped. */
export async function readTranscript(file: string): Promise<Transcript> {
  const prompts: Prompt[] = [];
  let aiTitle: string | undefined;
  let summary: string | undefined;
  const lines = createInterface({
    input: createReadStream(file, { encoding: "utf8" }),
    crlfDelay: Infinity,
  });
  for await (const line of lines) {
    if (!line.startsWith("{")) continue;
    let entry: unknown;
    try {
      entry = JSON.parse(line);
    } catch {
      continue;
    }
    const recorded = recordedTitle(entry);
    aiTitle ??= recorded.aiTitle;
    summary ??= recorded.summary;
    const text = promptText(entry);
    const at = timestamp(entry);
    if (text !== undefined && at !== undefined) prompts.push({ text, at });
  }
  const title = aiTitle ?? summary;
  return title === undefined ? { prompts } : { title, prompts };
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
 * Claude Code names a project's directory after the project's path, every character but a letter or
 * digit turned to '-'. That loses which dash was a '/', so a name is decoded against the file
 * system: from the root, each child directory whose encoded name begins the rest of the name is
 * tried in turn. Only paths that exist come back (node/web/sources.ml, decode_project_dir).
 */
async function decodeProjectDir(root: string, name: string): Promise<string[]> {
  const go = async (dir: string, rest: string): Promise<string[]> => {
    const found: string[] = [];
    for (const child of await names(dir)) {
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

/** Whether a directory holds financial records at its top level or one level below (node/web/sources.ml, holds_financial_records). */
async function holdsFinancialRecords(dir: string): Promise<boolean> {
  const financial = (n: string) => FINANCIAL_RECORD_SUFFIXES.some((s) => n.toLowerCase().endsWith(s));
  const top = (await names(dir)).filter((n) => !n.startsWith("."));
  if (top.some(financial)) return true;
  for (const n of top) {
    const below = await names(join(dir, n));
    if (below.some((c) => !c.startsWith(".") && financial(c))) return true;
  }
  return false;
}

/**
 * Whether any path a project directory's name can decode to holds financial records, itself or in
 * the repository around it (node/web/sources.ml, financial_project).
 */
async function financialProject(root: string, name: string): Promise<boolean> {
  for (const path of await decodeProjectDir(root, name)) {
    if (await holdsFinancialRecords(path)) return true;
    for (let d = path; ; d = dirname(d)) {
      if (await exists(join(d, ".git"))) {
        if (await holdsFinancialRecords(d)) return true;
        break;
      }
      if (dirname(d) === d) break;
    }
  }
  return false;
}

/**
 * The transcripts under a chosen path: the path's own top-level `.jsonl` files when it is a project
 * directory, chosen by the member whatever it holds, else those of each project directory one level
 * below it (`~/.claude/projects`) that is not a financial project. `root` is where a project's name
 * is decoded from.
 */
export async function sessionFiles(path: string, root = "/"): Promise<string[]> {
  if (!(await isDir(path))) return [];
  const own = await jsonlFiles(path);
  if (own.length > 0) return own;
  const files: string[] = [];
  for (const n of (await names(path)).filter((n) => !n.startsWith(".")).sort()) {
    const sub = join(path, n);
    if ((await isDir(sub)) && !(await financialProject(root, n))) files.push(...(await jsonlFiles(sub)));
  }
  return files;
}

/**
 * The sessions under a path with at least one prompt of the day. A transcript not modified since
 * the day began cannot hold one and is not read (the node filters by mtime the same way).
 */
export async function sessionsOfDay(path: string, day: Day): Promise<Session[]> {
  const sessions: Session[] = [];
  for (const file of await sessionFiles(path)) {
    let mtime: number;
    try {
      mtime = (await stat(file)).mtimeMs;
    } catch {
      continue;
    }
    if (mtime < day.start) continue;
    const { title, prompts } = await readTranscript(file);
    const first = prompts[0];
    if (first === undefined) continue;
    if (!prompts.some((p) => p.at >= day.start && p.at < day.end)) continue;
    sessions.push(title === undefined ? { file, title: first.text, titlePrompt: first, prompts } : { file, title, prompts });
  }
  return sessions;
}
