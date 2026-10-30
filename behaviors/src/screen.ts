// The screens of the nightly note, step 3 of docs/design.md, The nightly note: the deny layer
// checks the draft, then the business-information screen. A deny trip refuses the note; a screen
// flag holds it for approval. A note is never rewritten.
//
// This module runs the PII half of the deny layer (src/pii.ts) and leaves a hook for the
// business-information screen: a second model call, separate from the writer and also with no
// tools, asked only whether the draft names a customer, partner, employer project, deal, figure or
// unreleased product. It cannot clear a note, only hold it. It is not implemented here (the
// second half of #57); an implementation satisfies BusinessScreen and is passed in.

import { screenPii, type Verdict } from "./pii.ts";

export type { Verdict };

/** What the business-information screen answers: hold the note, with the reason, or let it pass. */
export type BusinessAnswer = { hold: false } | { hold: true; reason: string };

/** The business-information screen's contract. A fake satisfies it in tests. */
export interface BusinessScreen {
  ask(note: string): Promise<BusinessAnswer>;
}

/** The screen that is not there yet: it holds nothing. */
export const noBusinessScreen: BusinessScreen = { ask: () => Promise.resolve({ hold: false }) };

/** The note's fate, in the node's terms: posted as is, refused by a rule, or held for approval. */
export type Outcome = { outcome: "pass" } | { outcome: "refused"; rule: string } | { outcome: "held"; reason: string };

export interface ScreenOptions {
  /** The circle's member and agent names. */
  allow?: string[];
  business?: BusinessScreen;
}

/** The deny layer first; the business screen runs only on a note the deny layer passed. */
export async function screenNote(note: string, options: ScreenOptions = {}): Promise<Outcome> {
  const verdict = screenPii(note, options.allow ?? []);
  if (!verdict.ok) return { outcome: "refused", rule: verdict.rule };
  const answer = await (options.business ?? noBusinessScreen).ask(note);
  return answer.hold ? { outcome: "held", reason: answer.reason } : { outcome: "pass" };
}
