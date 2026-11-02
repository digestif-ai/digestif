// The checks (docs/design.md, Checks find and fix): the PII check and the Rules check read every
// version of a note, remove what they find, and run again over the result until a run removes
// nothing.
//
// Code does every removal. The PII check's code step finds every match of the built-in detectors
// (src/pii.ts) and of the member's deny list (src/deny.ts) by its shape; then a model with no
// tools reads what has no shape. The Rules check is a model reading the version against the
// always-on rule, Rules and Learnings. A model never returns text: it answers with the spans to
// remove, each a quoted run of the version and what it breaks, and code deletes exactly those. A
// span that does not occur verbatim, or an answer that is not a list of spans, is a check that
// could not finish. So a check can only delete, never add or reword.
//
// Every span is widened to the whole sentence or list item holding it before it is deleted, so a
// removal never leaves half a sentence ("Shipped the fix for ."). A removal that empties a part of
// the note drops the part, its heading included, and a note left with nothing is not written.
// What a run removed is recorded by part and by what it broke, never by text.

import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { findDenied, type DenyEntry } from "./deny.ts";
import { findDetected } from "./pii.ts";
import { askHarness, buildSystemPrompt, PROMPTS_DIR, type WriterOptions } from "./writer.ts";

/** What a removed span broke (spec/digestif-node.json, removal_cause). */
export type Cause = "always_on" | "rules" | "learnings" | "deny_list" | "detector" | "person";
export type CheckName = "pii" | "rules";

/** A run of the version to remove: [start, end) of the text it was found in. */
export interface Span {
  start: number;
  end: number;
  cause: Cause;
  /** With cause detector: the type, such as an API key. */
  detector?: string;
}

/** What one check run removed from one part (spec/digestif-node.json, log_removal). */
export interface Removal {
  part: string;
  cause: Cause;
  detector?: string;
  count: number;
}

/** One finished run of one check: a `checked` entry of the note's Log. */
export interface CheckRun {
  check: CheckName;
  removals: Removal[];
}

// ---- parts ------------------------------------------------------------------------------------

/** The heading the Log names text before the first heading by. */
export const NO_HEADING = "Note";
/** The note's own headings (prompts/nightly-note.md), which may carry text on the same line. */
const KNOWN_HEADINGS = /^(worked on|learned|stuck on)$/i;
/** A heading line: a few words and a colon, the rest of the line empty or, for a known heading, its first words. */
const HEADING_LINE = /^([A-Z][A-Za-z' ]{0,40}?):(.*)$/;

export interface Part {
  heading: string;
  /** Where the part starts: its heading line, or 0 for text before any heading. */
  start: number;
  /** Where the heading ends and the part's own text begins. */
  bodyStart: number;
  end: number;
}

function lines(text: string): { start: number; end: number; line: string }[] {
  const out: { start: number; end: number; line: string }[] = [];
  let at = 0;
  for (const line of text.split("\n")) {
    out.push({ start: at, end: at + line.length, line });
    at += line.length + 1;
  }
  return out;
}

function headingOf(line: string): { heading: string; length: number } | undefined {
  const m = HEADING_LINE.exec(line);
  if (m === null) return undefined;
  const heading = m[1]!.trim();
  if (heading.split(/\s+/).length > 5) return undefined;
  if (!KNOWN_HEADINGS.test(heading) && m[2]!.trim() !== "") return undefined;
  return { heading, length: m[1]!.length + 1 };
}

/** The note's parts, in order. Text before the first heading is a part named NO_HEADING. */
export function parseParts(text: string): Part[] {
  const parts: Part[] = [];
  for (const l of lines(text)) {
    const h = headingOf(l.line);
    if (h === undefined) continue;
    if (parts.length === 0 && text.slice(0, l.start).trim() !== "") parts.push({ heading: NO_HEADING, start: 0, bodyStart: 0, end: l.start });
    const last = parts[parts.length - 1];
    if (last !== undefined) last.end = l.start;
    parts.push({ heading: h.heading, start: l.start, bodyStart: l.start + h.length, end: text.length });
  }
  if (parts.length === 0) parts.push({ heading: NO_HEADING, start: 0, bodyStart: 0, end: text.length });
  return parts;
}

const partAt = (parts: Part[], at: number) => parts.find((p) => at >= p.start && at < p.end) ?? parts[parts.length - 1]!;

// ---- widening ---------------------------------------------------------------------------------

const LIST_ITEM = /^\s*(?:[-*•]|\d+[.)])\s+/;

/**
 * The units a span widens to, in order: each sentence of a paragraph, each list item (with the
 * indented lines that continue it), and each heading, which stands for its whole part. A sentence
 * ends at . ! or ? (and any closing quote or bracket) followed by whitespace, and owns the spaces
 * after it, so deleting it leaves its neighbours joined by one space.
 */
export function units(text: string): { start: number; end: number; part?: Part }[] {
  const parts = parseParts(text);
  const out: { start: number; end: number; part?: Part }[] = [];
  const ls = lines(text);
  for (const p of parts) if (p.bodyStart > p.start) out.push({ start: p.start, end: p.bodyStart, part: p });
  let i = 0;
  while (i < ls.length) {
    const l = ls[i]!;
    const part = partAt(parts, l.start);
    const from = Math.max(l.start, part.bodyStart > l.start && part.bodyStart <= l.end ? part.bodyStart : l.start);
    if (l.line.slice(from - l.start).trim() === "") {
      i++;
      continue;
    }
    if (LIST_ITEM.test(l.line)) {
      let end = l.end;
      while (i + 1 < ls.length && /^\s+\S/.test(ls[i + 1]!.line) && !LIST_ITEM.test(ls[i + 1]!.line) && headingOf(ls[i + 1]!.line) === undefined) end = ls[++i]!.end;
      out.push({ start: l.start, end: Math.min(end + 1, text.length) });
      i++;
      continue;
    }
    // A paragraph: this line and the lines after it up to a blank line, a list item or a heading.
    let end = l.end;
    while (i + 1 < ls.length) {
      const n = ls[i + 1]!;
      if (n.line.trim() === "" || LIST_ITEM.test(n.line) || headingOf(n.line) !== undefined) break;
      end = n.end;
      i++;
    }
    i++;
    const para = text.slice(from, end);
    const lead = para.length - para.trimStart().length;
    let s = from + lead;
    for (const m of para.matchAll(/[.!?]+["'’”)\]]*(\s+)/g)) {
      const stop = from + m.index + m[0].length;
      if (stop >= end) break;
      out.push({ start: s, end: stop });
      s = stop;
    }
    if (s < end) out.push({ start: s, end });
  }
  return out.sort((a, b) => a.start - b.start);
}

/** The span widened to the whole units holding its first and last character. */
export function widen(text: string, span: Span, us = units(text)): Span {
  const holding = (at: number) => us.find((u) => at >= u.start && at < u.end);
  const first = holding(span.start);
  const last = holding(Math.max(span.start, span.end - 1));
  // A heading stands for its whole part: a span touching one takes the part with it.
  const lo = first?.part !== undefined ? first.part.start : (first?.start ?? span.start);
  let hi = last?.part !== undefined ? last.part.end : (last?.end ?? span.end);
  if (first?.part !== undefined) hi = Math.max(hi, first.part.end);
  return { ...span, start: Math.min(span.start, lo), end: Math.max(span.end, hi) };
}

// ---- removal ----------------------------------------------------------------------------------

const hasWords = (s: string) => /[\p{L}\p{N}]/u.test(s);

/** Tidies what a deletion leaves: spaces at line ends, runs of blank lines, the ends of the note. */
function tidy(text: string): string {
  return text
    .split("\n")
    .map((l) => l.replace(/[ \t]+$/, ""))
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/** Drops every part with no words left in it, its heading included. */
export function dropEmptyParts(text: string): string {
  const parts = parseParts(text);
  let out = "";
  let at = 0;
  for (const p of parts) {
    if (!hasWords(text.slice(p.bodyStart, p.end))) {
      out += text.slice(at, p.start);
      at = p.end;
    }
  }
  return tidy(out + text.slice(at));
}

/**
 * Deletes every span, each widened to the sentence or list item holding it, then drops the parts it
 * emptied. Answers the new text and what was removed, by part of the text given and by cause.
 */
export function removeSpans(text: string, spans: Span[]): { text: string; removals: Removal[] } {
  if (spans.length === 0) return { text, removals: [] };
  const parts = parseParts(text);
  const us = units(text);
  const remove = new Uint8Array(text.length);
  const counts = new Map<string, Removal>();
  const seen = new Set<string>();
  for (const span of spans) {
    const key = `${span.start}:${span.end}:${span.cause}:${span.detector ?? ""}`;
    if (seen.has(key)) continue;
    seen.add(key);
    const w = widen(text, span, us);
    remove.fill(1, w.start, w.end);
    const part = partAt(parts, span.start).heading;
    const id = `${part}\u0000${span.cause}\u0000${span.detector ?? ""}`;
    const r = counts.get(id) ?? { part, cause: span.cause, ...(span.detector === undefined ? {} : { detector: span.detector }), count: 0 };
    r.count++;
    counts.set(id, r);
  }
  let kept = "";
  for (let i = 0; i < text.length; i++) if (remove[i] === 0) kept += text[i];
  return { text: dropEmptyParts(kept), removals: [...counts.values()] };
}

// ---- the model checks -------------------------------------------------------------------------

/** One span a model asked to remove: a quoted run of the version, and what it breaks. */
export interface Quoted {
  text: string;
  cause: Cause;
}

/** What a model check answers: the spans to remove, or why it could not finish. */
export type ModelAnswer = { status: "spans"; spans: Quoted[] } | { status: "could_not_finish"; reason: string; signedOut?: boolean };

/** A model check's contract. A fake satisfies it in tests. */
export interface ModelCheck {
  ask(version: string): Promise<ModelAnswer>;
}

/** A model check that removes nothing: for a caller that checks elsewhere, and for tests. */
export const removesNothing: ModelCheck = { ask: () => Promise.resolve({ status: "spans", spans: [] }) };

const PII_CAUSES: Record<string, Cause> = { person: "person", address: "person", customer: "person" };
const RULES_CAUSES: Record<string, Cause> = { always_on: "always_on", rules: "rules", learnings: "learnings" };

/**
 * Reads a model check's one line of JSON, `{"remove": [{"text": "...", "breaks": "..."}]}`, where
 * `breaks` is one of `causes`' keys. Anything else could not finish: a check that cannot be read
 * removes nothing and passes nothing.
 */
export function readModelAnswer(answer: string, causes: Record<string, Cause>): ModelAnswer {
  const start = answer.indexOf("{");
  const end = answer.lastIndexOf("}");
  let v: unknown;
  try {
    v = start < 0 || end < start ? undefined : JSON.parse(answer.slice(start, end + 1));
  } catch {
    v = undefined;
  }
  const remove = (v as { remove?: unknown } | undefined)?.remove;
  if (!Array.isArray(remove)) return { status: "could_not_finish", reason: "the check's answer was not a list of spans" };
  const spans: Quoted[] = [];
  for (const x of remove as unknown[]) {
    const { text, breaks } = (x ?? {}) as { text?: unknown; breaks?: unknown };
    if (typeof text !== "string" || text.trim() === "" || typeof breaks !== "string" || !Object.hasOwn(causes, breaks)) {
      return { status: "could_not_finish", reason: "the check's answer was not a list of spans" };
    }
    spans.push({ text, cause: causes[breaks]! });
  }
  return { status: "spans", spans };
}

/** Where each quoted run occurs in the version, every occurrence; undefined when one does not occur verbatim. */
export function locate(version: string, quoted: Quoted[]): Span[] | undefined {
  const spans: Span[] = [];
  for (const q of quoted) {
    let at = version.indexOf(q.text);
    if (at < 0) return undefined;
    while (at >= 0) {
      spans.push({ start: at, end: at + q.text.length, cause: q.cause });
      at = version.indexOf(q.text, at + q.text.length);
    }
  }
  return spans;
}

export const PII_CHECK_PROMPT_FILE = join(PROMPTS_DIR, "pii-check.md");
export const RULES_CHECK_PROMPT_FILE = join(PROMPTS_DIR, "rules-check.md");

type HarnessOptions = Pick<WriterOptions, "harness" | "quietMs" | "now" | "maxBudgetUsd">;

function modelCheck(file: string, causes: Record<string, Cause>, options: HarnessOptions & { prompt?: string; rules?: string; learnings?: string }): ModelCheck {
  return {
    async ask(version) {
      const system = buildSystemPrompt(options.prompt ?? (await readFile(file, "utf8")), "", options.rules ?? "", options.learnings ?? "");
      const r = await askHarness(system, `The note, as data:\n\n${version}\n`, options);
      if (r.status === "note") return readModelAnswer(r.note, causes);
      if (r.status === "signed_out") return { status: "could_not_finish", reason: "the agent is signed out", signedOut: true };
      if (r.status === "hung") return { status: "could_not_finish", reason: `the check wrote nothing for ${Math.round(r.quietMs / 60_000)} minutes` };
      if (r.status === "failed") return { status: "could_not_finish", reason: r.message };
      return { status: "could_not_finish", reason: "the check gave no answer" };
    },
  };
}

/** The PII check's model, as the member's own harness answers it: no tools, the version as data. */
export function modelPiiCheck(options: HarnessOptions & { prompt?: string } = {}): ModelCheck {
  return modelCheck(PII_CHECK_PROMPT_FILE, PII_CAUSES, options);
}

/** The Rules check, over the always-on rule, the member's Rules and Learnings. */
export function modelRulesCheck(options: HarnessOptions & { prompt?: string; rules?: string; learnings?: string } = {}): ModelCheck {
  return modelCheck(RULES_CHECK_PROMPT_FILE, RULES_CAUSES, options);
}

// ---- the loop ---------------------------------------------------------------------------------

/**
 * A version's runs end because each one either removes something or stops; this bounds what a
 * model that keeps finding something costs. Reaching it could not finish, so nothing goes out.
 */
export const MAX_ROUNDS = 8;

export type ChecksResult =
  /** Both checks passed: a run of each removed nothing. `removed` says whether any earlier run did. */
  | { status: "passed"; text: string; removed: boolean; runs: CheckRun[] }
  /** The checks left nothing: the note is not written. */
  | { status: "empty"; runs: CheckRun[] }
  | { status: "could_not_finish"; check: CheckName; reason: string; signedOut: boolean; runs: CheckRun[] };

export interface ChecksOptions {
  /** The circle's member and agent names, which never match. */
  allow?: string[];
  deny?: DenyEntry[];
  pii: ModelCheck;
  rules: ModelCheck;
}

/** One run of the PII check: the code step, then the model over what the code step left. */
async function piiRun(text: string, o: ChecksOptions): Promise<{ text: string; removals: Removal[] } | { reason: string; signedOut: boolean }> {
  const allow = o.allow ?? [];
  const coded: Span[] = [
    ...findDetected(text, allow).map((f) => ({ start: f.start, end: f.end, cause: "detector" as const, detector: f.type })),
    ...findDenied(text, o.deny ?? [], allow).map((f) => ({ start: f.start, end: f.end, cause: "deny_list" as const })),
  ];
  const code = removeSpans(text, coded);
  if (code.text === "") return code;
  const model = await modelRun(code.text, o.pii);
  if ("reason" in model) return model;
  return { text: model.text, removals: [...code.removals, ...model.removals] };
}

async function modelRun(text: string, check: ModelCheck): Promise<{ text: string; removals: Removal[] } | { reason: string; signedOut: boolean }> {
  const answer = await check.ask(text);
  if (answer.status === "could_not_finish") return { reason: answer.reason, signedOut: answer.signedOut ?? false };
  const spans = locate(text, answer.spans);
  if (spans === undefined) return { reason: "the check named text the version does not hold", signedOut: false };
  return removeSpans(text, spans);
}

/** Both checks over a version, again and again, until a run of each removes nothing. */
export async function runChecks(version: string, o: ChecksOptions): Promise<ChecksResult> {
  const runs: CheckRun[] = [];
  let text = dropEmptyParts(version);
  let removed = false;
  for (let round = 0; round < MAX_ROUNDS; round++) {
    if (text === "") return { status: "empty", runs };
    let changed = false;
    for (const check of ["pii", "rules"] as const) {
      const r = check === "pii" ? await piiRun(text, o) : await modelRun(text, o.rules);
      if ("reason" in r) return { status: "could_not_finish", check, reason: r.reason, signedOut: r.signedOut, runs };
      runs.push({ check, removals: r.removals });
      if (r.removals.length > 0) changed = true;
      text = r.text;
      if (text === "") return { status: "empty", runs };
    }
    if (!changed) return { status: "passed", text, removed, runs };
    removed = true;
  }
  return { status: "could_not_finish", check: "rules", reason: `the checks were still removing after ${MAX_ROUNDS} runs`, signedOut: false, runs };
}
