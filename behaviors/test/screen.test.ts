// The business-information screen (src/screen.ts, prompts/business-screen.md) against the fake
// harness: what it answers, and that it can only hold.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";
import { CATEGORIES, modelBusinessScreen, readScreenAnswer, UNANSWERED } from "../src/screen.ts";

const harness = join(import.meta.dirname, "fake-harness.mjs");
let dir: string;
beforeEach(() => (dir = mkdtempSync(join(tmpdir(), "digestif-screen-test-"))));
afterEach(() => {
  for (const k of ["FAKE_SCREEN_FIXTURE", "FAKE_EXIT"]) delete process.env[k];
  rmSync(dir, { recursive: true, force: true });
});
const answer = (text: string) => {
  const f = join(dir, "answer.txt");
  writeFileSync(f, text);
  process.env["FAKE_SCREEN_FIXTURE"] = f;
};

test("the answer is read strictly: a pass, a category's reason, or a hold as unanswered", () => {
  assert.deepEqual(readScreenAnswer('{"hold": false}'), { hold: false });
  assert.deepEqual(readScreenAnswer('```json\n{"hold": true, "category": "financial"}\n```'), { hold: true, reason: CATEGORIES.financial });
  assert.deepEqual(readScreenAnswer('{"hold": true, "category": "deal"}'), { hold: true, reason: "The screen flagged a deal." });
  for (const t of ["", "looks fine", '{"hold": "no"}', '{"hold": true, "category": "toString"}', '{"hold": true}', "{not json}"]) {
    assert.deepEqual(readScreenAnswer(t), { hold: true, reason: UNANSWERED }, t);
  }
});

test("the model screen holds a flag and passes a clean note; a failed or empty run holds", async () => {
  const screen = modelBusinessScreen({ harness });
  answer('{"hold": true, "category": "financial"}');
  assert.deepEqual(await screen.ask("Worked on: x."), { hold: true, reason: CATEGORIES.financial });
  answer('{"hold": false}');
  assert.deepEqual(await screen.ask("Worked on: x."), { hold: false });
  answer("");
  assert.deepEqual(await screen.ask("Worked on: x."), { hold: true, reason: UNANSWERED });
  answer('{"hold": false}');
  process.env["FAKE_EXIT"] = "1";
  assert.deepEqual(await screen.ask("Worked on: x."), { hold: true, reason: UNANSWERED });
});

test("the screen's instructions, not the rule, say money software is shareable and real people's money is not", async () => {
  const { readFileSync } = await import("node:fs");
  const { SCREEN_PROMPT_FILE } = await import("../src/screen.ts");
  const { ALWAYS_ON_RULES } = await import("../src/writer.ts");
  const prompt = readFileSync(SCREEN_PROMPT_FILE, "utf8");
  assert.match(prompt, /Work on software that handles money can be shared/);
  assert.match(prompt, /What that software shows\s+about real people's money is flagged/);
  assert.ok(!ALWAYS_ON_RULES.includes("software"));
  for (const c of Object.keys(CATEGORIES)) assert.ok(prompt.includes(`- ${c}:`), c);
});
