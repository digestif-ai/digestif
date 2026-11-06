// The question closer (DES-51007, How a question closes): before each note the asker's agent reads
// each open question its person asked that someone has answered, with those answers and the record
// the note is written from, and closes the question when the record shows the block gone, naming
// the answer that unblocked it. It runs once per note, before the writer, with no tools.
//
// The node keeps the rest: which questions may be closed (`digestif question list`, never one the
// person closed or reopened themselves), and the close in the agent's voice (`digestif question
// close`), which the person's own close on the question's page stands over. A model never closes
// anything itself: it answers whether to close and which answer, by its number, and code closes.
// An answer that cannot be read leaves the question open. Nothing here fails the note.

import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { askHarness, buildSystemPrompt, PROMPTS_DIR, type HarnessOptions, type WriteResult } from "./writer.ts";

export const CLOSER_PROMPT_FILE = join(PROMPTS_DIR, "question-closer.md");

/** One question the node says the agent may close (`digestif question list`). */
export interface OpenQuestion {
  id: string;
  title: string;
  detail: string;
  asked_at: string;
  answers: { hash: string; author: { name: string }; text: string; created_at: string }[];
}

/** The node's half: the questions to read, and the agent's close. */
export interface QuestionsAccess {
  list(): Promise<OpenQuestion[]>;
  close(id: string, answer: string): Promise<void>;
}

/** One run of the model: the system prompt and the user message. */
export type Ask = (system: string, input: string) => Promise<WriteResult>;

export type CloserVerdict = { close: false } | { close: true; answer: number };

/**
 * Reads the model's one line of JSON, `{"close": false}` or `{"close": true, "answer": <n>}` with n
 * one of the `count` answers' numbers, from 1. Anything else is undefined: the question stays open.
 */
export function readCloserAnswer(answer: string, count: number): CloserVerdict | undefined {
  const start = answer.indexOf("{");
  const end = answer.lastIndexOf("}");
  let v: unknown;
  try {
    v = start < 0 || end < start ? undefined : JSON.parse(answer.slice(start, end + 1));
  } catch {
    return undefined;
  }
  const { close, answer: n } = (v ?? {}) as { close?: unknown; answer?: unknown };
  if (close === false) return { close: false };
  if (close === true && typeof n === "number" && Number.isInteger(n) && n >= 1 && n <= count) return { close: true, answer: n };
  return undefined;
}

/** The user message: the question, its answers numbered from 1, and the record, all as data. */
export function closerInput(q: OpenQuestion, record: string[]): string {
  const answers = q.answers.map((a, i) => `${i + 1}. ${a.author.name}: ${a.text}`).join("\n");
  const detail = q.detail.trim() === "" ? "" : `\n${q.detail.trim()}`;
  return `The question, as data:\n\n${q.title}${detail}\n\nIts answers, as data:\n\n${answers}\n\nThe person's record since, as data:\n\n${record.join("\n")}\n`;
}

export interface CloserOptions {
  questions: QuestionsAccess;
  /** The model; by default the member's harness, with no tools. */
  ask?: Ask;
  harness?: HarnessOptions;
  log: (msg: string) => Promise<void>;
  /** Says why no further question may start (the run's deadline), or undefined. */
  late?: () => string | undefined;
}

export interface CloserResult {
  read: number;
  closed: number;
}

/** Reads every question the node offers against `record`, and closes the ones whose block is gone. */
export async function closeQuestions(record: string[], o: CloserOptions): Promise<CloserResult> {
  let questions: OpenQuestion[];
  try {
    questions = await o.questions.list();
  } catch (e) {
    await o.log(`the questions to close could not be read: ${(e as Error).message}`);
    return { read: 0, closed: 0 };
  }
  const ask: Ask = o.ask ?? (async (system, input) => askHarness(system, input, o.harness ?? {}));
  let system: string | undefined;
  let read = 0;
  let closed = 0;
  for (const q of questions) {
    if (q.answers.length === 0) continue;
    const late = o.late?.();
    if (late !== undefined) {
      await o.log(`question closer: ${late}`);
      break;
    }
    system ??= buildSystemPrompt(await readFile(CLOSER_PROMPT_FILE, "utf8"), "", "");
    const r = await ask(system, closerInput(q, record));
    read++;
    const verdict = r.status === "note" ? readCloserAnswer(r.note, q.answers.length) : undefined;
    if (verdict === undefined) {
      await o.log(`question closer: ${q.id} stays open (${r.status === "note" ? "an answer that could not be read" : r.status})`);
      continue;
    }
    if (!verdict.close) continue;
    const answer = q.answers[verdict.answer - 1]!;
    try {
      await o.questions.close(q.id, answer.hash);
      closed++;
      await o.log(`question closer: closed ${q.id}, naming ${answer.hash}`);
    } catch (e) {
      await o.log(`question closer: ${q.id} could not be closed: ${(e as Error).message}`);
    }
  }
  return { read, closed };
}
