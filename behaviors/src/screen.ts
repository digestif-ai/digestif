// The screens of the nightly note, step 3 of docs/design.md, The nightly note: the deny layer
// checks the draft, then the business-information screen. A deny trip refuses the note; a screen
// flag holds it for its person. A note is never rewritten.
//
// The deny layer here is the PII half (src/pii.ts); the node runs its own deny layer again on
// whatever it is handed. The business-information screen is a second model call, separate from
// the writer and also with no tools (prompts/business-screen.md), asked only whether the draft
// names a customer, partner, employer project, deal, figure, unreleased product or anything about a
// real person's money. It cannot clear a note or refuse one, only hold it: a flag is handed to the
// node with `digestif note --hold`, which keeps the note for its person whatever their approval
// settings. An answer the screen did not give, or gave in a shape this module cannot read, holds.

import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { screenPii, type Verdict } from "./pii.ts";
import { askHarness, buildSystemPrompt, PROMPTS_DIR, type WriterOptions } from "./writer.ts";

export type { Verdict };

export const SCREEN_PROMPT_FILE = join(PROMPTS_DIR, "business-screen.md");

/** What the screen may flag, and the reason the person is shown for each. */
export const CATEGORIES = {
  customer: "The screen flagged a customer.",
  partner: "The screen flagged a partner.",
  employer_project: "The screen flagged an employer project.",
  deal: "The screen flagged a deal.",
  figure: "The screen flagged a business figure.",
  unreleased_product: "The screen flagged an unreleased product.",
  financial: "The screen flagged financial information.",
} as const;
export type Category = keyof typeof CATEGORIES;
/** The reason when the screen gave no answer it could read: the note is held all the same. */
export const UNANSWERED = "The screen gave no answer, so the note waits for you.";

/** What the business-information screen answers: hold the note, with the reason, or let it pass. */
export type BusinessAnswer = { hold: false } | { hold: true; reason: string };

/** The business-information screen's contract. A fake satisfies it in tests. */
export interface BusinessScreen {
  ask(note: string): Promise<BusinessAnswer>;
}

/** A screen that holds nothing: for a caller that screens elsewhere, and for tests. */
export const noBusinessScreen: BusinessScreen = { ask: () => Promise.resolve({ hold: false }) };

/**
 * Reads the screen's one line of JSON. `{"hold": false}` passes; `{"hold": true, "category": …}`
 * holds with that category's reason; anything else holds as unanswered.
 */
export function readScreenAnswer(text: string): BusinessAnswer {
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  let v: unknown;
  try {
    v = start < 0 || end < start ? undefined : JSON.parse(text.slice(start, end + 1));
  } catch {
    v = undefined;
  }
  if (typeof v !== "object" || v === null) return { hold: true, reason: UNANSWERED };
  const { hold, category } = v as { hold?: unknown; category?: unknown };
  if (hold === false) return { hold: false };
  if (hold === true && typeof category === "string" && Object.hasOwn(CATEGORIES, category)) return { hold: true, reason: CATEGORIES[category as Category] };
  return { hold: true, reason: UNANSWERED };
}

/** The screen as the member's own harness answers it: print mode, no tools, the note as data. */
export function modelBusinessScreen(options: Pick<WriterOptions, "harness" | "quietMs" | "now" | "maxBudgetUsd"> & { prompt?: string } = {}): BusinessScreen {
  return {
    async ask(note) {
      const system = buildSystemPrompt(options.prompt ?? (await readFile(SCREEN_PROMPT_FILE, "utf8")), "", "");
      const r = await askHarness(system, `The note, as data:\n\n${note}\n`, options);
      return r.status === "note" ? readScreenAnswer(r.note) : { hold: true, reason: UNANSWERED };
    },
  };
}

/** The note's fate, in the node's terms: posted as is, refused by a rule, or held for its person. */
export type Outcome = { outcome: "pass" } | { outcome: "refused"; rule: string } | { outcome: "held"; reason: string };

export interface ScreenOptions {
  /** The circle's member and agent names. */
  allow?: string[];
  business: BusinessScreen;
}

/** The deny layer first; the business screen runs only on a note the deny layer passed. */
export async function screenNote(note: string, options: ScreenOptions): Promise<Outcome> {
  const verdict = screenPii(note, options.allow ?? []);
  if (!verdict.ok) return { outcome: "refused", rule: verdict.rule };
  const answer = await options.business.ask(note);
  return answer.hold ? { outcome: "held", reason: answer.reason } : { outcome: "pass" };
}
