// Claude Code sessions under ~/.claude/projects: one directory per project (the project path with
// its separators turned to dashes), one JSONL transcript per session at its top level. Deeper
// transcripts (a subagent's, under a directory named after the session) are another agent's
// conversation, not the member's, and are left alone.
//
// Only two things are read from a transcript: the member's own prompts (entries of type "user"
// whose content the member typed) and their timestamps. Assistant text, tool calls and tool results
// are never read, nor are the slash-command and system entries Claude Code records as the user,
// its compaction summaries, or prompts a program sent through the Agent SDK.

import { createReadStream } from "node:fs";
import { readdir, stat } from "node:fs/promises";
import { join } from "node:path";
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
  /** The session's first prompt, which Claude Code shows as the session's title. */
  title: Prompt;
  /** Every prompt of the session in transcript order, the title among them. */
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

function timestamp(entry: unknown): number | undefined {
  if (typeof entry !== "object" || entry === null) return undefined;
  const t = (entry as Record<string, unknown>).timestamp;
  if (typeof t !== "string") return undefined;
  const ms = Date.parse(t);
  return Number.isNaN(ms) ? undefined : ms;
}

/** The member's prompts of one transcript, in order. Lines that are not JSON objects are skipped. */
export async function readPrompts(file: string): Promise<Prompt[]> {
  const prompts: Prompt[] = [];
  const lines = createInterface({ input: createReadStream(file, { encoding: "utf8" }), crlfDelay: Infinity });
  for await (const line of lines) {
    if (!line.startsWith("{")) continue;
    let entry: unknown;
    try {
      entry = JSON.parse(line);
    } catch {
      continue;
    }
    const text = promptText(entry);
    const at = timestamp(entry);
    if (text !== undefined && at !== undefined) prompts.push({ text, at });
  }
  return prompts;
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

/**
 * The transcripts under a chosen path: the path's own top-level `.jsonl` files when it is a project
 * directory, else those of each project directory one level below it (`~/.claude/projects`).
 */
export async function sessionFiles(path: string): Promise<string[]> {
  if (!(await isDir(path))) return [];
  const own = await jsonlFiles(path);
  if (own.length > 0) return own;
  let names: string[];
  try {
    names = await readdir(path);
  } catch {
    return [];
  }
  const files: string[] = [];
  for (const n of names.filter((n) => !n.startsWith(".")).sort()) {
    const sub = join(path, n);
    if (await isDir(sub)) files.push(...(await jsonlFiles(sub)));
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
    const prompts = await readPrompts(file);
    const title = prompts[0];
    if (title === undefined) continue;
    if (!prompts.some((p) => p.at >= day.start && p.at < day.end)) continue;
    sessions.push({ file, title, prompts });
  }
  return sessions;
}
