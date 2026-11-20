// The Inbox agent's run (docs/design.md, The Inbox agent): one run of the member's agent per sync,
// under the member's Inbox prompt, over the whole batch the read behavior kept (src/read.ts). It
// answers one JSON object; code checks it and acts on it. The guards are here and in the node,
// never in the prompt: the batch is framed as untrusted data, an answer is sent only when the agent
// says the brief and Rules allow it AND both checks remove nothing from it (the node then reads it
// through the deny layer, and keeps it for the member while they are Onboarding or Paused), and
// nothing here can pick a choice or send a draft. The node marks every message the run read
// Reviewed, with the agent's review line. An answer to a note is the member's reply to it in the
// circle, under the same guards; one kept is the note's draft reply, which the member edits and
// sends. A draft the member asked for is a run of its own over that note, which records only the
// answer and never sends it (ISS-83154).
//
// The run that reads messages has no tools, so nothing a message says can be run. Filing an idea is
// the only act on one: for each filing the reading run wrote, a second run whose one tool is the
// harness's shell, started in an empty directory, files it where the member's Inbox prompt says, and
// its link counts only when it is on a tracker that prompt names (DIG-215). That run is never shown a message, only the
// work in the reading run's own words and, added by code, who had the idea and the link to it. What
// it filed becomes a work notice to the member and a credit to the idea's author (ISS-65274), which
// says what was taken from the author's message when the reading run wrote that (ISS-83259); the
// filing run is never handed it.
//
// A practice is the other thing the run may take from the circle: one line of how the member's
// agent works, which it saw working for another member's agent. The node adopts it into the
// member's practices only while they turned adopting on, and otherwise offers it to them as a
// choice of Adopt or Not now (ISS-80159). Every reading run reads the adopted practices under the
// member's own prompt; the filing run is never handed one, so no practice says where or how work is
// filed. Each practice carries the credit to its author, written and checked here as a filed idea's
// is, with `adopted` saying how; the node sends it only once it saves the line (ISS-85004).

import { appendFileSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { runChecks, modelPiiCheck, modelRulesCheck, type ModelCheck } from "./checks.ts";
import type { DenyEntry } from "./deny.ts";
import { agentProblem, askHarness, buildSystemPrompt, PROMPTS_DIR, type AgentProblem, type HarnessOptions } from "./writer.ts";

/** The code's frame around the member's prompt: the always-on rule, the guards and the answer's shape. */
export const INBOX_RUN_PROMPT_FILE = join(PROMPTS_DIR, "inbox-run.md");
/** The release's default Inbox prompt, which the node saves for every member with an agent. */
export const INBOX_PROMPT_FILE = join(PROMPTS_DIR, "inbox.md");
export const INBOX_PROMPT_PLACEHOLDER = "{{inbox_prompt}}";
export const PRACTICES_PLACEHOLDER = "{{practices}}";
/** The frame of the filing run: the always-on rule, the member's Inbox prompt and the one act it may take. */
export const INBOX_FILE_PROMPT_FILE = join(PROMPTS_DIR, "inbox-file.md");

/** How many runs a message is read in before it is left unreviewed. */
export const MAX_READS = 3;

/** One message of the batch, as the run is shown it. */
export interface BatchMessage {
  ref: string;
  /** The envelope hash: the node's id of the note or item. */
  hash: string;
  /** "note", or the item's kind: "question", "choice" or "notice". */
  type: string;
  author: string;
  author_name: string;
  voice: string;
  created_at: string;
  /** A note's text; an item's title and detail. */
  text: string;
  /** On an item: its subject, options and answers so far. */
  subject?: string;
  options?: string[];
  answers?: string[];
  /** Where the member reads it on their own node: the note's page, or the item's. */
  link?: string;
  /** True when the member asked for a draft reply to it: the run writes one in `answers`, and it is never sent. */
  asked?: boolean;
}

/** One of the member's own notes the run is handed, to match the circle's against. */
export interface OwnNote {
  shared_at: string;
  text: string;
}

export interface Member {
  identity: string;
  name: string;
  is_self: boolean;
}

export const AGENT_SUBJECTS = ["intro", "share", "behavior", "work"] as const;
export type AgentSubject = (typeof AGENT_SUBJECTS)[number];

export interface AgentItem {
  subject: AgentSubject;
  ref: string;
  title: string;
  detail: string;
  members: string[];
  circle: boolean;
  kind?: "question" | "notice";
  /** The words of the message it came from that led to it, verbatim (ISS-85463). */
  quote?: string;
}

const isStr = (v: unknown): v is string => typeof v === "string";
const nonEmpty = (v: unknown): v is string => isStr(v) && v.trim() !== "";
const oneLine = (s: string): string => s.replace(/\s*\n\s*/g, " ").trim();

/** An idea the reading run judged worth filing, in its own words. */
export interface Filing {
  ref: string;
  title: string;
  body: string;
  /** The agent's judgement that the member's brief and Rules let the credit line go out. */
  credit_within_brief: boolean;
  /**
   * What it took from the author's message, addressed to them, for the credit alone (ISS-83259):
   * one line of at most TAKEN_MAX characters, else absent. Never handed to the filing run.
   */
  taken?: string;
  /** The words of the author's message the idea is in, verbatim (ISS-85463). */
  quote?: string;
}

/** The longest `quote` a run may record: about a paragraph; a longer one is dropped. */
export const QUOTE_MAX = 1000;

/** A run's `quote` as the node is handed it: the words as written, trimmed, within QUOTE_MAX, or undefined. */
export function quoteOf(v: unknown): string | undefined {
  if (!isStr(v)) return undefined;
  const q = v.trim();
  return q === "" || q.length > QUOTE_MAX ? undefined : q;
}

/** The longest `taken` a credit carries; a longer one is dropped, never cut mid-sentence. */
export const TAKEN_MAX = 400;

/** A filing's `taken` as a credit carries it: one line within TAKEN_MAX, or undefined. */
export function takenOf(v: unknown): string | undefined {
  if (!isStr(v)) return undefined;
  const t = oneLine(v);
  return t === "" || t.length > TAKEN_MAX ? undefined : t;
}

/** A practice the run saw working for another member's agent, in its own words, one line. */
export interface Practice {
  ref: string;
  text: string;
  /** The agent's judgement that the member's brief and Rules let the credit to its author go out. */
  credit_within_brief: boolean;
  /** The words of the message that show it, verbatim (ISS-85463). */
  quote?: string;
}

/** How a credit's idea was adopted (spec/digestif-node.json, credit_adopted). */
export type CreditAdopted = "as_work" | "as_how_agent_works";

/** The run's answer, checked. */
export interface RunAnswer {
  reviews: Map<string, string>;
  remember: string[];
  answers: { ref: string; text: string; within_brief: boolean }[];
  items: AgentItem[];
  filings: Filing[];
  practices: Practice[];
}

const objects = (v: unknown): Record<string, unknown>[] | undefined =>
  v === undefined ? [] : Array.isArray(v) && v.every((x) => typeof x === "object" && x !== null && !Array.isArray(x)) ? (v as Record<string, unknown>[]) : undefined;

/** Strips one pair of code fences an agent may wrap its JSON in, though asked not to. */
function unfence(text: string): string {
  const m = /^```(?:json)?\s*\n([\s\S]*?)\n```$/.exec(text.trim());
  return m === null ? text.trim() : m[1]!.trim();
}

/** The agent's answer over a batch whose refs are `refs`: a RunAnswer, or why the run could not finish. */
export function parseRun(answer: string, refs: Set<string>): RunAnswer | { error: string } {
  let j: unknown;
  try {
    j = JSON.parse(unfence(answer));
  } catch {
    return { error: "the answer is not JSON" };
  }
  if (typeof j !== "object" || j === null || Array.isArray(j)) return { error: "the answer is not a JSON object" };
  const o = j as Record<string, unknown>;
  const reviews = objects(o["reviews"]);
  const answers = objects(o["answers"]);
  const items = objects(o["items"]);
  const filings = objects(o["filings"]);
  const practices = objects(o["practices"]);
  const remember = o["remember"] === undefined ? [] : o["remember"];
  if (reviews === undefined || answers === undefined || items === undefined || filings === undefined || practices === undefined) return { error: "reviews, answers, items, filings and practices are lists of objects" };
  if (!Array.isArray(remember) || !remember.every(isStr)) return { error: "remember is a list of lines" };
  const known = (ref: unknown): ref is string => isStr(ref) && refs.has(ref);
  const out: RunAnswer = { reviews: new Map(), remember: remember.map((l) => l.replace(/\s*\n\s*/g, " ").trim()).filter((l) => l !== ""), answers: [], items: [], filings: [], practices: [] };
  for (const r of reviews) {
    if (!known(r["ref"])) return { error: "a review names a message the batch does not hold" };
    out.reviews.set(r["ref"], isStr(r["review"]) ? r["review"].replace(/\s*\n\s*/g, " ").trim() : "");
  }
  for (const a of answers) {
    if (!known(a["ref"])) return { error: "an answer names a message the batch does not hold" };
    if (!nonEmpty(a["text"])) return { error: "an answer has no text" };
    out.answers.push({ ref: a["ref"], text: a["text"].trim(), within_brief: a["within_brief"] === true });
  }
  for (const i of items) {
    const subject = AGENT_SUBJECTS.find((s) => s === i["subject"]);
    if (subject === undefined) return { error: "an item names a subject the Inbox agent does not write" };
    if (!known(i["ref"])) return { error: "an item names a message the batch does not hold" };
    if (!nonEmpty(i["title"])) return { error: "an item has no title" };
    const members = i["members"] === undefined ? [] : i["members"];
    if (!Array.isArray(members) || !members.every(isStr)) return { error: "an item's members are identities" };
    const kind = i["kind"] === "question" || i["kind"] === "notice" ? i["kind"] : undefined;
    const quote = quoteOf(i["quote"]);
    out.items.push({
      subject,
      ref: i["ref"],
      title: i["title"].trim(),
      detail: isStr(i["detail"]) ? i["detail"].trim() : "",
      members,
      circle: i["circle"] === true,
      ...(kind === undefined ? {} : { kind }),
      ...(quote === undefined ? {} : { quote }),
    });
  }
  for (const f of filings) {
    if (!known(f["ref"])) return { error: "a filing names a message the batch does not hold" };
    if (!nonEmpty(f["title"])) return { error: "a filing has no title" };
    const taken = takenOf(f["taken"]);
    const quote = quoteOf(f["quote"]);
    out.filings.push({
      ref: f["ref"],
      title: oneLine(f["title"]),
      body: isStr(f["body"]) ? f["body"].trim() : "",
      credit_within_brief: f["credit_within_brief"] === true,
      ...(taken === undefined ? {} : { taken }),
      ...(quote === undefined ? {} : { quote }),
    });
  }
  for (const p of practices) {
    if (!known(p["ref"])) return { error: "a practice names a message the batch does not hold" };
    if (!nonEmpty(p["text"])) return { error: "a practice has no text" };
    const quote = quoteOf(p["quote"]);
    out.practices.push({ ref: p["ref"], text: oneLine(p["text"]), credit_within_brief: p["credit_within_brief"] === true, ...(quote === undefined ? {} : { quote }) });
  }
  return out;
}

/** The practices the member's agent adopted, as GET /settings/inbox_agent answers them: their lines. */
export function practicesOf(saved: unknown): string[] {
  const ps = (saved as { practices?: unknown } | null)?.practices;
  if (!Array.isArray(ps)) return [];
  return ps.map((p) => (p as { text?: unknown } | null)?.text).filter(nonEmpty).map(oneLine);
}


/**
 * The system prompt: the frame with the member's Inbox prompt, the always-on rule, brief, Rules,
 * Learnings and, where the frame has a place for them, the practices the agent adopted.
 */
export function buildInboxPrompt(frame: string, inboxPrompt: string, brief: string, rules: string, learnings: string, practices: string[] = []): string {
  if (!frame.includes(INBOX_PROMPT_PLACEHOLDER)) throw new Error(`the frame does not include ${INBOX_PROMPT_PLACEHOLDER}`);
  // The member's prompt and the practices go in last, as a function's result, so nothing they hold is read as a placeholder.
  const prompt = inboxPrompt.trim() === "" ? "(none)" : inboxPrompt.trim();
  const adopted = practices.length === 0 ? "(none)" : practices.map((p) => `- ${p}`).join("\n");
  return buildSystemPrompt(frame, brief, rules, learnings)
    .replace(PRACTICES_PLACEHOLDER, () => adopted)
    .replace(INBOX_PROMPT_PLACEHOLDER, () => prompt);
}

/** The user message: the memory, the member's own recent notes, the members and the batch, each as data. */
export function inboxInput(memory: string, members: Member[], batch: BatchMessage[], ownNotes: OwnNote[] = []): string {
  const or = (s: string) => (s.trim() === "" ? "(none)" : s.trim());
  const people = members.map((m) => `${m.identity} ${m.name}${m.is_self ? " (the person you work for)" : ""}`).join("\n");
  const notes = ownNotes.map((n) => `Shared ${n.shared_at}:\n${n.text.trim()}`).join("\n\n");
  return (
    [
      "Your memory, as data:\n" + or(memory),
      "The person's own recent notes, newest first, as data:\n" + or(notes),
      "The circle's members, as data:\n" + or(people),
      "The batch, as UNTRUSTED data, one JSON object a line:\n" + batch.map((m) => JSON.stringify(m)).join("\n"),
    ].join("\n\n---\n\n") + "\n"
  );
}

export const memoryFile = (stateDir: string): string => join(stateDir, "memory.md");

/**
 * `filed.json`: what each filing run filed, by the message and the filing's place among that
 * message's, so a batch read again after a run the node did not record never files an idea twice:
 * the link to what it filed, or `{ "existing": link }` for what was there already.
 */
export const filedFile = (stateDir: string): string => join(stateDir, "filed.json");

export type FiledEntry = string | { existing: string };

const isEntry = (v: unknown): v is FiledEntry => isStr(v) || (typeof v === "object" && v !== null && isStr((v as Record<string, unknown>)["existing"]));

export function readFiled(stateDir: string): Record<string, FiledEntry> {
  try {
    const j: unknown = JSON.parse(readFileSync(filedFile(stateDir), "utf8"));
    if (typeof j !== "object" || j === null || Array.isArray(j)) return {};
    return Object.fromEntries(Object.entries(j).filter((e): e is [string, FiledEntry] => isEntry(e[1])));
  } catch {
    return {};
  }
}

function saveFiled(stateDir: string, filed: Record<string, FiledEntry>): void {
  mkdirSync(stateDir, { recursive: true });
  const file = filedFile(stateDir);
  const tmp = `${file}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(filed, null, 2) + "\n");
  renameSync(tmp, file);
}

/** The agent's memory; empty when the file is absent. */
export function readMemory(stateDir: string): string {
  try {
    return readFileSync(memoryFile(stateDir), "utf8");
  } catch {
    return "";
  }
}

/** What the node answers POST /inbox_agent/runs (spec/digestif-node.json, inbox_run). */
interface InboxRun {
  reviewed?: number;
  adopted?: string[];
  answers?: { item?: string; outcome?: string }[];
  items?: unknown[];
  problems?: string[];
}

export interface InboxRunArgs {
  stateDir: string;
  harness: HarnessOptions;
  inboxPrompt: string;
  /** The practices the member's agent adopted from the circle, which the reading run reads and the filing run never does. */
  practices?: string[];
  brief: string;
  rules: string;
  learnings: string;
  deny: DenyEntry[];
  allow: string[];
  members: Member[];
  batch: BatchMessage[];
  /** POST /api/v0/inbox_agent/runs: the node's answer, or why it could not be reached. */
  post: (body: unknown) => Promise<InboxRun>;
  log: (line: string) => void;
  /** The checks an answer passes before it is sent; the model checks when absent. */
  checks?: { pii: ModelCheck; rules: ModelCheck };
  /** The member's own recent notes, newest first: what they work on and are stuck on. */
  ownNotes?: OwnNote[];
  /**
   * The member asked for a draft reply to every message in the batch (ISS-83154): only the
   * answers are recorded, each kept for the member and never sent, and nothing else the run
   * wrote (reviews, memory, items, filings, practices) is, since the batch was read already.
   */
  draftOnly?: boolean;
}

/** What a run came to: `done` when the node recorded it, else the problem that leaves the batch unreviewed. */
export type InboxRunResult = { status: "done"; sent: number; kept: number; items: number; filed: number; adopted: number } | { status: "failed"; why: string; problem: AgentProblem | "failed" };

/** What a filing run may name as what it filed or found: a URL, an owner/repo#n, or a tracker key such as ISS-120. */
export const FILED_LINK = /^(?:https?:\/\/\S+|[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+#\d+|[A-Z][A-Z0-9]*-\d+)$/;

/** Why a filing run's link was refused. */
const NO_LINK = "it named no URL, owner/repo#n or key";

/** The cut of a refused answer the log keeps. */
export const REFUSED_ANSWER_MAX = 300;

/** What a filing run came to: what it filed, what was there already, or why it filed nothing. */
export type FiledOutcome = { link: string } | { existing: string } | { error: string };

/**
 * The filing run's answer: the link to what it filed; the link to what was already there, from a
 * member's Inbox prompt that still has the run look first (DIG-124); or why it filed nothing.
 */
export function parseFiled(answer: string): FiledOutcome {
  let j: unknown;
  try {
    j = JSON.parse(unfence(answer));
  } catch {
    return { error: "the answer is not JSON" };
  }
  if (typeof j !== "object" || j === null || Array.isArray(j)) return { error: "the answer is not a JSON object" };
  const o = j as Record<string, unknown>;
  const filed = o["filed"];
  if (filed === null || filed === undefined) {
    const existing = o["existing"];
    if (existing !== null && existing !== undefined) return isStr(existing) && FILED_LINK.test(existing.trim()) ? { existing: existing.trim() } : { error: NO_LINK };
    return { error: nonEmpty(o["why"]) ? oneLine(o["why"]).slice(0, 200) : "it filed nothing" };
  }
  if (!isStr(filed) || !FILED_LINK.test(filed.trim())) return { error: NO_LINK };
  return { link: filed.trim() };
}

/** A place the member's Inbox prompt names for work: a host, and the first segment of its path when it names one. */
export interface FilingPlace {
  host: string;
  owner?: string;
}

/** A host the prompt names, with or without a scheme, and the path after it. */
const NAMED_HOST = /(?:https?:\/\/)?((?:[a-z0-9-]+\.)+[a-z]{2,})(?::\d+)?(\/[^\s)\]>"'`,;]*)?/gi;
/** An owner/repo the prompt names, as a `gh` command or a GitHub reference does: an owner has no dot. */
const NAMED_REPO = /(?<![\w./:-])([A-Za-z0-9-]+)\/([A-Za-z0-9_.-]+)(?![\w/])/g;

/**
 * The places the member's Inbox prompt names for filing work: every URL or host in it, with the
 * first segment of the path it names (the owner or workspace), and every owner/repo, which is
 * GitHub's. The filing run's link must be in one of them (DIG-215).
 */
export function filingPlaces(inboxPrompt: string): FilingPlace[] {
  const places: FilingPlace[] = [];
  for (const m of inboxPrompt.matchAll(NAMED_HOST)) {
    const owner = (m[2] ?? "").split("/")[1]?.replace(/[.:]+$/, "");
    places.push({ host: m[1]!.toLowerCase(), ...(owner ? { owner: owner.toLowerCase() } : {}) });
  }
  for (const m of inboxPrompt.matchAll(NAMED_REPO)) places.push({ host: "github.com", owner: m[1]!.toLowerCase() });
  return places;
}

/**
 * Whether a filing run's link is where the member's Inbox prompt files work: a URL on a host the
 * prompt names, under the owner it names there when it names one; an owner/repo#n whose owner it
 * names. A tracker key is shown as text, never opened, so it is taken as it stands.
 */
export function onNamedTracker(link: string, places: FilingPlace[]): boolean {
  const repo = /^([A-Za-z0-9_.-]+)\/[A-Za-z0-9_.-]+#\d+$/.exec(link);
  if (repo !== null) return places.some((p) => p.owner === repo[1]!.toLowerCase());
  if (!/^https?:\/\//i.test(link)) return true;
  let u: URL;
  try {
    u = new URL(link);
  } catch {
    return false;
  }
  const first = u.pathname.split("/")[1]?.toLowerCase() ?? "";
  return places.some((p) => p.host === u.hostname.toLowerCase() && (p.owner === undefined || p.owner === first));
}

/** Why a link outside the places the Inbox prompt names was refused. */
const OFF_TRACKER = "the link it named is not on a tracker the Inbox prompt names";

/** A filing run's outcome with its link checked against the places the member's Inbox prompt names. */
export function checkFiled(r: FiledOutcome, inboxPrompt: string): FiledOutcome {
  const link = "link" in r ? r.link : "existing" in r ? r.existing : undefined;
  return link === undefined || onNamedTracker(link, filingPlaces(inboxPrompt)) ? r : { error: OFF_TRACKER };
}

/** What a message is, in a credit or a notice: a note, or an item by its kind. */
const noun = (m: BatchMessage): string => (m.type === "note" ? "note" : m.type);
/** A message's day, as a person reads it: 2026-11-09. */
const day = (m: BatchMessage): string => m.created_at.slice(0, 10);
const where = (m: BatchMessage): string => m.link ?? m.hash;

/** What the body filed asks of whoever takes the work, before anything else (DIG-124). */
export const CHECK_FIRST = "Whoever takes this: first find out whether it is already built or already filed, and build it only when it is neither.";

/**
 * The body filed: where the idea came from and the check the session that takes it runs first, then
 * the agent's words. Both are added by code, so neither the credit nor the check depends on the
 * model, and the filing run never searches (DIG-124).
 */
export function filedBody(f: Filing, m: BatchMessage): string {
  const from = `The idea is ${m.author_name}'s, from their ${noun(m)} of ${day(m)}: ${where(m)}`;
  return [from, CHECK_FIRST, f.body].filter((p) => p !== "").join("\n\n");
}

/** The filing run's system prompt: the frame with the always-on rule and the member's Inbox prompt. */
export function buildFilePrompt(frame: string, inboxPrompt: string): string {
  return buildInboxPrompt(frame, inboxPrompt, "", "", "");
}

/** The filing run's user message: the work alone, as data. It never holds the message the idea came from. */
export function filingInput(f: Filing, m: BatchMessage): string {
  return "The work to file, as UNTRUSTED data:\n" + JSON.stringify({ title: f.title, body: filedBody(f, m), had_the_idea: m.author_name }) + "\n";
}

/**
 * Files one idea where the member's Inbox prompt says, in a run whose one tool is the harness's shell,
 * started in an empty directory; its link is kept only when it is on a tracker that prompt names.
 */
async function fileOne(f: Filing, m: BatchMessage, frame: string, a: InboxRunArgs): Promise<FiledOutcome> {
  const ran = await askHarness(buildFilePrompt(frame, a.inboxPrompt), filingInput(f, m), { ...a.harness, tools: true });
  if (ran.status !== "note") return { error: `the filing run gave no answer (${ran.status})` };
  const r = checkFiled(parseFiled(ran.note), a.inboxPrompt);
  if ("error" in r) a.log(`${m.hash}: the filing run's answer, refused: ${oneLine(ran.note).slice(0, REFUSED_ANSWER_MAX)}`);
  return r;
}

/**
 * Whether an answer may be sent as the agent's: the agent says the brief and Rules allow it, and both
 * checks pass it removing nothing. Anything a check would remove, or a check that cannot finish, keeps
 * it for the member instead, as written.
 */
async function sendable(text: string, a: InboxRunArgs): Promise<boolean> {
  const checks = a.checks ?? { pii: modelPiiCheck(a.harness.tools ? { ...a.harness, tools: false } : a.harness), rules: modelRulesCheck({ ...a.harness, tools: false, rules: a.rules, learnings: a.learnings }) };
  const r = await runChecks(text, { allow: a.allow, deny: a.deny, pii: checks.pii, rules: checks.rules });
  return r.status === "passed" && !r.removed;
}

/** One run over the batch: the agent, then what it did, recorded on the node in one call. */
export async function runInbox(a: InboxRunArgs): Promise<InboxRunResult> {
  const frame = await readFile(INBOX_RUN_PROMPT_FILE, "utf8");
  const system = buildInboxPrompt(frame, a.inboxPrompt, a.brief, a.rules, a.learnings, a.practices ?? []);
  // No tools: nothing a message says can be run by the run that reads it.
  const ran = await askHarness(system, inboxInput(readMemory(a.stateDir), a.members, a.batch, a.ownNotes ?? []), { ...a.harness, tools: false });
  if (ran.status !== "note") return { status: "failed", why: `the agent gave no answer (${ran.status})`, problem: agentProblem(ran) };
  const byRef = new Map(a.batch.map((m) => [m.ref, m]));
  const d = parseRun(ran.note, new Set(byRef.keys()));
  if ("error" in d) return { status: "failed", why: `the agent's answer could not be used: ${d.error}`, problem: "model_unavailable" };
  const answers = [];
  for (const x of d.answers) {
    const m = byRef.get(x.ref)!;
    // A question is answered, and a note replied to in the circle (ISS-83154); a choice is the member's to pick and a notice is acknowledged.
    if (m.type !== "question" && m.type !== "note") {
      a.log(`${m.hash}: an answer to a ${m.type} is dropped`);
      continue;
    }
    const send = !a.draftOnly && m.asked !== true && x.within_brief && (await sendable(x.text, a));
    answers.push({ item: m.hash, text: x.text, send });
  }
  if (a.draftOnly) return postDrafts(a, answers);
  const me = a.members.find((m) => m.is_self);
  const self = me?.identity;
  const items: Record<string, unknown>[] = d.items.map((i) => ({
    subject: i.subject,
    title: i.title,
    detail: i.detail,
    about: byRef.get(i.ref)!.hash,
    circle: i.circle,
    members: i.members.filter((id) => id !== self),
    ...(i.kind === undefined ? {} : { kind: i.kind }),
    ...(i.quote === undefined ? {} : { quote: i.quote }),
  }));
  const reviews = new Map(a.batch.map((m) => [m.ref, d.reviews.get(m.ref) ?? ""]));
  const filed = await fileAll(d.filings, byRef, me?.name ?? "", a, items, reviews);
  const practices = [];
  for (const p of d.practices) {
    const m = byRef.get(p.ref)!;
    if (m.author === self) {
      a.log(`${m.hash}: the member's own message is never a practice from the circle`);
      continue;
    }
    practices.push({ text: p.text, about: m.hash, ...(p.quote === undefined ? {} : { quote: p.quote }), credit: await practiceCredit(p, m, me?.name ?? "", a) });
  }
  const reviewed = a.batch.map((m) => ({ hash: m.hash, review: reviews.get(m.ref) ?? "" }));
  let done: InboxRun;
  try {
    done = await a.post({ reviews: reviewed, answers, items, practices });
  } catch (e) {
    return { status: "failed", why: `the node did not record the run: ${(e as Error).message}`, problem: "failed" };
  }
  if (d.remember.length > 0) {
    mkdirSync(a.stateDir, { recursive: true });
    appendFileSync(memoryFile(a.stateDir), d.remember.join("\n") + "\n");
  }
  for (const p of done.problems ?? []) a.log(`the node did not apply: ${p}`);
  const outcomes = done.answers ?? [];
  return {
    status: "done",
    sent: outcomes.filter((o) => o.outcome === "sent").length,
    kept: outcomes.filter((o) => o.outcome === "kept").length,
    items: (done.items ?? []).length,
    filed,
    adopted: (done.adopted ?? []).length,
  };
}

/** A draft-only run's record: its answers alone, each kept for the member. */
async function postDrafts(a: InboxRunArgs, answers: { item: string; text: string; send: boolean }[]): Promise<InboxRunResult> {
  const drafted = new Set(answers.map((x) => x.item));
  for (const m of a.batch) if (!drafted.has(m.hash)) a.log(`${m.hash}: the agent wrote no draft reply`);
  if (answers.length === 0) return { status: "done", sent: 0, kept: 0, items: 0, filed: 0, adopted: 0 };
  let done: InboxRun;
  try {
    done = await a.post({ reviews: [], answers });
  } catch (e) {
    return { status: "failed", why: `the node did not record the drafts: ${(e as Error).message}`, problem: "failed" };
  }
  for (const p of done.problems ?? []) a.log(`the node did not apply: ${p}`);
  const outcomes = done.answers ?? [];
  return { status: "done", sent: 0, kept: outcomes.filter((o) => o.outcome === "kept").length, items: 0, filed: 0, adopted: 0 };
}

/**
 * Files every idea the reading run chose, one filing run each, and writes what came of it from the
 * filing alone, never from the agent's words (DIG-124): a work notice to the member whose title
 * starts with the outcome (Filed, Already filed, Could not file) and which carries the link as a
 * field of its own, and the same outcome, link and all, added to the message's review line. A filed
 * idea also gets a credit to its author (see `credits`), sent as the agent's when the agent says the
 * brief and Rules allow it and both checks remove nothing (the node then reads it through the deny
 * layer), else a draft the member sends. A run that takes several ideas from one message is one
 * event (DIG-306): one work notice for that message, and one credit to its author listing every
 * idea filed, never one each. Returns how many were filed.
 */
async function fileAll(filings: Filing[], byRef: Map<string, BatchMessage>, selfName: string, a: InboxRunArgs, items: Record<string, unknown>[], reviews: Map<string, string>): Promise<number> {
  if (filings.length === 0) return 0;
  const frame = await readFile(INBOX_FILE_PROMPT_FILE, "utf8");
  const self = a.members.find((m) => m.is_self)?.identity;
  const ledger = readFiled(a.stateDir);
  const place = new Map<string, number>();
  const outcomes = new Map<string, string[]>();
  const byMessage = new Map<string, { m: BatchMessage; filed: FiledIdea[] }>();
  let n = 0;
  for (const f of filings) {
    const m = byRef.get(f.ref)!;
    if (m.author === self) {
      a.log(`${m.hash}: the member's own message is never filed as an idea from the circle`);
      continue;
    }
    const k = place.get(m.hash) ?? 0;
    place.set(m.hash, k + 1);
    const key = `${m.hash} ${k}`;
    const before = ledger[key];
    const r: FiledOutcome = before === undefined ? await fileOne(f, m, frame, a) : isStr(before) ? { link: before } : { existing: before.existing };
    if (before === undefined && !("error" in r)) {
      ledger[key] = "link" in r ? r.link : { existing: r.existing };
      saveFiled(a.stateDir, ledger);
    }
    const o = filingOutcome(f, m, r);
    outcomes.set(f.ref, [...(outcomes.get(f.ref) ?? []), o.review]);
    a.log(`${m.hash}: ${o.log}`);
    const g = byMessage.get(m.hash) ?? { m, filed: [] };
    g.filed.push({ f, r });
    byMessage.set(m.hash, g);
    if ("link" in r) n++;
  }
  for (const { m, filed } of byMessage.values()) {
    items.push(workNotice(m, filed));
    const linked = filed.flatMap(({ f, r }) => ("link" in r ? [{ f, link: r.link }] : []));
    items.push(...(await credits(linked, m, selfName, a)));
  }
  for (const [ref, lines] of outcomes) reviews.set(ref, reviewWithFilings(reviews.get(ref) ?? "", lines));
  return n;
}

/** One idea a run filed, or tried to: the reading run's filing and what the filing run came to. */
export interface FiledIdea {
  f: Filing;
  r: FiledOutcome;
}

/** The one quote a group of ideas from one message carries: theirs when they hold one, else none. */
function oneQuote(fs: Filing[]): { quote?: string } {
  const qs = [...new Set(fs.flatMap((f) => (f.quote === undefined ? [] : [f.quote])))];
  return qs.length === 1 ? { quote: qs[0]! } : {};
}

/** Words without the stop a list line puts after them. */
const bare = (s: string): string => s.replace(/[\s.;:,]+$/, "");

/**
 * The work notice to the member about what came of a run's filings from one message: one filing's
 * as `filingOutcome` writes it; several, one notice (DIG-306) whose title counts them from the
 * outcome it leads with and whose detail lists each idea on its own line with its outcome and link.
 */
export function workNotice(m: BatchMessage, filed: FiledIdea[]): Record<string, unknown> {
  const quoted = oneQuote(filed.map((x) => x.f));
  if (filed.length === 1) {
    const o = filingOutcome(filed[0]!.f, m, filed[0]!.r);
    return { subject: "work", title: o.title, detail: o.detail, about: m.hash, ...quoted, ...(o.link === undefined ? {} : { link: o.link }), circle: false, members: [] };
  }
  const total = filed.length;
  const linked = filed.filter((x) => "link" in x.r).length;
  const existing = filed.filter((x) => "existing" in x.r).length;
  const of = (k: number, verb: string) => `${verb} ${k} of ${m.author_name}'s ${k === total ? "" : `${total} `}ideas`;
  const title = linked > 0 ? of(linked, "Filed") : existing > 0 ? of(existing, "Already filed") : of(total, "Could not file");
  const lines = filed.map(({ f, r }) => ("link" in r ? `- Filed ${bare(f.title)}, as ${r.link}.` : "existing" in r ? `- Already filed ${bare(f.title)}, as ${r.existing}.` : `- Could not file ${bare(f.title)}: ${r.error}.`));
  const detail = [`${m.author_name} had them, in their ${noun(m)}: ${where(m)}.`, ...lines].join("\n");
  return { subject: "work", title, detail, about: m.hash, ...quoted, circle: false, members: [] };
}

/** One filing's outcome as each place shows it: the work notice's title, detail and link, the review line's part, the log's line. */
export function filingOutcome(f: Filing, m: BatchMessage, r: FiledOutcome): { title: string; detail: string; link?: string; review: string; log: string } {
  const idea = `${m.author_name}'s idea: ${f.title}`;
  const had = `${m.author_name} had it, in their ${noun(m)}: ${where(m)}.`;
  if ("link" in r) return { title: `Filed ${idea}`, detail: `${had} Filed as ${r.link}.`, link: r.link, review: `Filed ${idea} (${r.link})`, log: `filed ${r.link}` };
  if ("existing" in r) return { title: `Already filed ${idea}`, detail: `${had} It was already filed, as ${r.existing}.`, link: r.existing, review: `Already filed ${idea} (${r.existing})`, log: `already filed as ${r.existing}` };
  return { title: `Could not file ${idea}`, detail: `${had} It could not be filed: ${r.error}.`, review: `Could not file ${idea}`, log: `the filing run filed nothing: ${r.error}` };
}

/** A review line with what came of the message's filings after what the agent said it did, if anything. */
export function reviewWithFilings(said: string, outcomes: string[]): string {
  const own = said.trim().replace(/[.;]+$/, "");
  return [own, ...outcomes].filter((p) => p !== "").join("; ");
}

/** A credit's detail: the message's day, what was taken from it when the run said, and the link. */
export function creditDetail(m: BatchMessage, link: string, taken?: string): string {
  return `From your ${noun(m)} of ${day(m)}.${takenSaid(taken)} Filed as ${link}.`;
}

/** What was taken, as a credit says it after what comes before it: " Taken from it: <it>." or nothing. */
const takenSaid = (taken?: string): string => (taken === undefined ? "" : ` Taken from it: ${/[.!?]$/.test(taken) ? taken : `${taken}.`}`);

/** One idea of a credit that names several: its title, where it was filed, and what was taken when said. */
export interface CreditIdea {
  title: string;
  link: string;
  taken?: string;
}

/**
 * A credit for several ideas from one message (DIG-306): "<member> is adopting <n> of your ideas",
 * its detail the message's day and then each idea on its own line, with what was taken from it when
 * said and the link to the work filed for it, which the Inbox shows as a link.
 */
export function creditWords(selfName: string, m: BatchMessage, ideas: CreditIdea[]): { title: string; detail: string } {
  const lines = ideas.map((i) => `- ${bare(i.title)}, filed as ${i.link}.${takenSaid(i.taken)}`);
  return { title: `${selfName} is adopting ${ideas.length} of your ideas`, detail: [`From your ${noun(m)} of ${day(m)}:`, ...lines].join("\n") };
}

/** One idea's credit as it would go alone, and what was taken that it carries. */
type OneCredit = { title: string; detail: string; send: boolean; taken?: string };

/**
 * The credit to an idea's author: with what was taken from their message when the agent says the
 * brief allows the credit and both checks pass it whole; when a check would cut it, the credit as
 * it reads without what was taken, sent if that passes; past the brief, a draft with it in.
 */
async function credit(f: Filing, m: BatchMessage, selfName: string, link: string, a: InboxRunArgs): Promise<OneCredit> {
  const title = `${selfName} is adopting your idea: ${f.title}`;
  const full = { title, detail: creditDetail(m, link, f.taken), ...(f.taken === undefined ? {} : { taken: f.taken }) };
  if (!f.credit_within_brief) return { ...full, send: false };
  if (await sendable(`${full.title}\n\n${full.detail}`, a)) return { ...full, send: true };
  if (f.taken === undefined) return { ...full, send: false };
  a.log(`${m.hash}: the credit goes without what was taken, which a check would cut`);
  const plain = creditDetail(m, link);
  if (await sendable(`${title}\n\n${plain}`, a)) return { title, detail: plain, send: true };
  return { ...full, send: false };
}

/**
 * The credits to one message's author for the ideas a run filed from it (DIG-306). One idea is the
 * credit `credit` writes. Several are one credit listing every idea: each idea is first judged as
 * its own credit would be, so the guards are unchanged; those that would be sent are one credit,
 * sent only when both checks pass it whole as well, and the rest, with what was taken in them, one
 * draft the member sends. A credit naming several ideas carries their links in its detail, since an
 * item has one link.
 */
async function credits(linked: { f: Filing; link: string }[], m: BatchMessage, selfName: string, a: InboxRunArgs): Promise<Record<string, unknown>[]> {
  const each: (OneCredit & { f: Filing; link: string })[] = [];
  for (const x of linked) each.push({ ...x, ...(await credit(x.f, m, selfName, x.link, a)) });
  const base = { subject: "credit", adopted: "as_work" satisfies CreditAdopted, about: m.hash, circle: false, members: [m.author] };
  const one = (c: (typeof each)[number]) => ({ ...base, ...oneQuote([c.f]), link: c.link, title: c.title, detail: c.detail, send: c.send });
  const many = (cs: typeof each, ideas: CreditIdea[], send: boolean) => ({ ...base, ...oneQuote(cs.map((c) => c.f)), ...creditWords(selfName, m, ideas), send });
  let sent = each.filter((c) => c.send);
  if (sent.length > 1) {
    const w = creditWords(selfName, m, sent.map((c) => ({ title: c.f.title, link: c.link, ...(c.taken === undefined ? {} : { taken: c.taken }) })));
    if (!(await sendable(`${w.title}\n\n${w.detail}`, a))) {
      a.log(`${m.hash}: the credit naming ${sent.length} ideas is kept for the member, which a check would cut`);
      sent = [];
    }
  }
  const kept = each.filter((c) => !sent.includes(c));
  const out: Record<string, unknown>[] = [];
  if (sent.length === 1) out.push(one(sent[0]!));
  if (sent.length > 1) out.push(many(sent, sent.map((c) => ({ title: c.f.title, link: c.link, ...(c.taken === undefined ? {} : { taken: c.taken }) })), true));
  if (kept.length === 1) out.push({ ...one(kept[0]!), detail: creditDetail(m, kept[0]!.link, kept[0]!.f.taken), send: false });
  if (kept.length > 1) out.push(many(kept, kept.map((c) => ({ title: c.f.title, link: c.link, ...(c.f.taken === undefined ? {} : { taken: c.f.taken }) })), false));
  return out;
}

/** A practice credit's detail: how it was taken and the message it came from; no link, since nothing was filed. */
export function practiceCreditDetail(m: BatchMessage): string {
  return `Taken into how their agent works, from your ${noun(m)} of ${day(m)}.`;
}

/**
 * The credit to a practice's author (ISS-85004), held by the node beside the line and sent only once
 * it saves it: "<member> is adopting your idea: <the line>", sent as the agent's when the agent says
 * the brief allows it and both checks pass it whole, else a draft the member sends.
 */
export async function practiceCredit(p: Practice, m: BatchMessage, selfName: string, a: InboxRunArgs): Promise<{ title: string; detail: string; send: boolean }> {
  const title = `${selfName} is adopting your idea: ${p.text}`;
  const detail = practiceCreditDetail(m);
  const send = p.credit_within_brief && (await sendable(`${title}\n\n${detail}`, a));
  return { title, detail, send };
}
