// Extract: the first step of the nightly note (docs/design.md, The nightly note). Code, not the
// agent, pulls the day's digest from the chosen sources: commit subjects, session titles and the
// member's own prompts, never tool output or diffs, and the lines of any command source. The lines mirror node/web/sources.ml, so the
// node's preview and the nightly note agree on what the writer is given.

import { homedir } from "node:os";
import type { Day } from "./day.ts";
import { commandLines } from "./command.ts";
import { commitSubjects } from "./git.ts";
import { itemLine, sessionsOfDay } from "./sessions.ts";
import { untilde, type Source } from "./sources.ts";

/**
 * node/web/sources.ml, max_lines: the digest is at most this many lines after deduplication. The
 * note is read by agents, so the writer gets the whole day, not a sample of it.
 */
export const MAX_LINES = 500;

/** The digest stops before the line that would take it past this many characters. */
export const MAX_DIGEST_CHARS = 100_000;

/** The lines up to MAX_LINES and MAX_DIGEST_CHARS, in order. */
export function cap(lines: Line[]): Line[] {
  const out: Line[] = [];
  let chars = 0;
  for (const l of lines.slice(0, MAX_LINES)) {
    chars += l.kind.length + 2 + l.text.length + 1;
    if (chars > MAX_DIGEST_CHARS) break;
    out.push(l);
  }
  return out;
}

/** A command source's lines carry its label as their kind. */
export type LineKind = "commit" | "session" | "prompt" | (string & {});

export interface Line {
  kind: LineKind;
  text: string;
}

export interface ExtractOptions {
  /** The home directory ~ expands to in source paths. Defaults to the user's. */
  home?: string;
}

/** The digest lines, one per item, as `kind: text`, the way the node writes them. */
export function render(lines: Line[]): string[] {
  return lines.map((l) => `${l.kind}: ${l.text}`);
}

/** Keeps the first of equal lines, as dedupe in node/web/sources.ml does. */
export function dedupe(lines: Line[]): Line[] {
  const seen = new Set<string>();
  return lines.filter((l) => {
    const key = `${l.kind}: ${l.text}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

async function gitLines(paths: string[], day: Day): Promise<Line[]> {
  const lines: Line[] = [];
  for (const repo of paths) {
    for (const subject of await commitSubjects(repo, day)) lines.push({ kind: "commit", text: subject });
  }
  return lines;
}

async function sessionLines(paths: string[], day: Day): Promise<Line[]> {
  const sessions = [];
  for (const path of paths) sessions.push(...(await sessionsOfDay(path, day)));
  const inDay = (at: number) => at >= day.start && at < day.end;
  const firstOfDay = (s: { prompts: { at: number }[] }) => s.prompts.find((p) => inDay(p.at))?.at ?? 0;
  // Sessions in the order the member picked them up that day; files tie-break for determinism.
  sessions.sort((a, b) => firstOfDay(a) - firstOfDay(b) || (a.file < b.file ? -1 : a.file > b.file ? 1 : 0));
  const lines: Line[] = [];
  for (const s of sessions) {
    lines.push({ kind: "session", text: itemLine(s.title.text) });
    // The title is the first prompt; when it was typed today it is not repeated as a prompt.
    for (const p of s.prompts) {
      if (p !== s.title && inDay(p.at)) lines.push({ kind: "prompt", text: itemLine(p.text) });
    }
  }
  return lines.filter((l) => l.text !== "");
}

export interface Extracted {
  lines: Line[];
  /** Why each command source that failed gave no lines, naming it. */
  failures: string[];
}

/**
 * The day's digest lines from the chosen sources, in the order the sources are given, deduplicated
 * and capped at MAX_LINES and MAX_DIGEST_CHARS, and why any command source gave none. An unknown kind contributes nothing.
 */
export async function extractWithFailures(sources: Source[], day: Day, options: ExtractOptions = {}): Promise<Extracted> {
  const home = options.home ?? homedir();
  const lines: Line[] = [];
  const failures: string[] = [];
  for (const s of sources) {
    const paths = s.paths.map((p) => untilde(p, home));
    switch (s.kind) {
      case "git":
        lines.push(...(await gitLines(paths, day)));
        break;
      case "claude_code":
        lines.push(...(await sessionLines(paths, day)));
        break;
      case "command": {
        const r = await commandLines(paths, day.start / 1000, s.label);
        if (r.ok) lines.push(...r.lines.map((text) => ({ kind: s.label, text })));
        else failures.push(r.reason);
        break;
      }
    }
  }
  return { lines: cap(dedupe(lines)), failures };
}

/** The day's digest lines, as extractWithFailures without the failures. */
export async function extract(sources: Source[], day: Day, options: ExtractOptions = {}): Promise<Line[]> {
  return (await extractWithFailures(sources, day, options)).lines;
}
