// The checks (docs/design.md, Checks find and fix): spans widened to the sentence or list item
// holding them, an emptied part dropped and an empty note not written, the model's answer read as
// spans or as could-not-finish, the deny list in the code step, and the rerun until a run removes
// nothing. Every value is made up: reserved example domains and published test numbers.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { dropEmptyParts, locate, parseParts, readModelAnswer, removesNothing, removeSpans, RULES_CHECK_PROMPT_FILE, runChecks, type ModelCheck, type Span } from "../src/checks.ts";
import { findDenied, readDenyList } from "../src/deny.ts";
import { findDetected } from "../src/pii.ts";
import { buildSystemPrompt } from "../src/writer.ts";

const span = (text: string, run: string, cause: Span["cause"] = "rules"): Span => {
  const start = text.indexOf(run);
  assert.ok(start >= 0, run);
  return { start, end: start + run.length, cause };
};

/** A model that removes each run it is given while the version still holds it. */
const removing = (runs: string[], cause: Span["cause"] = "rules"): ModelCheck & { seen: string[] } => {
  const seen: string[] = [];
  return {
    seen,
    ask: async (v) => {
      seen.push(v);
      return { status: "spans", spans: runs.filter((r) => v.includes(r)).map((text) => ({ text, cause })) };
    },
  };
};

test("parts: the note's headings, inline or alone, and text before the first", () => {
  const note = "Intro line.\nWorked on: the fetcher.\nLearned:\nbackoff.\nStuck on: nothing.";
  assert.deepEqual(
    parseParts(note).map((p) => [p.heading, note.slice(p.start, p.end)]),
    [
      ["Note", "Intro line.\n"],
      ["Worked on", "Worked on: the fetcher.\n"],
      ["Learned", "Learned:\nbackoff.\n"],
      ["Stuck on", "Stuck on: nothing."],
    ],
  );
  // A sentence that merely has a colon in it is not a heading.
  assert.equal(parseParts("Worked on: the fetcher.\nThe fix: a retry with backoff and a cap.").length, 1);
});

test("a removal never leaves half a sentence: a span widens to the sentence holding it", () => {
  const note = "Worked on: Shipped the fix for Acme Corp. Then tidied the docs.\nLearned: retries.";
  const r = removeSpans(note, [span(note, "Acme Corp")]);
  assert.equal(r.text, "Worked on: Then tidied the docs.\nLearned: retries.");
  assert.ok(!r.text.includes("Shipped the fix for"), "no 'Shipped the fix for .' is left behind");
  assert.deepEqual(r.removals, [{ part: "Worked on", cause: "rules", count: 1 }]);
  // A span across two sentences takes both.
  const two = "Learned: one thing. Another thing. A third.";
  assert.equal(removeSpans(two, [span(two, "thing. Another")]).text, "Learned: A third.");
});

test("a span in a list item takes the whole item, its continuation lines included", () => {
  const note = "Worked on:\n- the fetcher's retry\n- a call with Jane Roe about\n  the launch plan\n- the docs\nLearned: x.";
  assert.equal(removeSpans(note, [span(note, "Jane Roe", "person")]).text, "Worked on:\n- the fetcher's retry\n- the docs\nLearned: x.");
});

test("an emptied part is dropped with its heading, and a note left with nothing is empty", () => {
  const note = "Worked on: the Acme deal.\nLearned: backoff.\nStuck on: nothing.";
  assert.equal(removeSpans(note, [span(note, "Acme")]).text, "Learned: backoff.\nStuck on: nothing.");
  assert.equal(dropEmptyParts("Worked on:\n\nLearned: x.\nStuck on: - "), "Learned: x.");
  const all = removeSpans(note, [span(note, "Acme"), span(note, "backoff"), span(note, "nothing")]);
  assert.equal(all.text, "");
  // A span on a heading takes its whole part.
  assert.equal(removeSpans(note, [span(note, "Stuck on")]).text, "Worked on: the Acme deal.\nLearned: backoff.");
});

test("a model's answer is a list of spans; anything else could not finish", () => {
  const causes = { rules: "rules" as const };
  assert.deepEqual(readModelAnswer('{"remove": []}', causes), { status: "spans", spans: [] });
  assert.deepEqual(readModelAnswer('Here: {"remove": [{"text": "Acme", "breaks": "rules"}]}', causes), { status: "spans", spans: [{ text: "Acme", cause: "rules" }] });
  for (const bad of ["", "the note is fine", '{"hold": false}', '{"remove": [{"text": "Acme"}]}', '{"remove": [{"text": "", "breaks": "rules"}]}', '{"remove": [{"text": "x", "breaks": "style"}]}', '{"text": "a rewritten note"}']) {
    assert.equal(readModelAnswer(bad, causes).status, "could_not_finish", bad);
  }
  // Every occurrence of a quoted run is located; a run the version does not hold is not.
  assert.deepEqual(locate("a b a", [{ text: "a", cause: "rules" }])?.map((s) => s.start), [0, 4]);
  assert.equal(locate("a b a", [{ text: "c", cause: "rules" }]), undefined);
});

test("a span that does not occur verbatim is a check that could not finish, and nothing goes out", async () => {
  const pii: ModelCheck = { ask: async () => ({ status: "spans", spans: [{ text: "a rewording of the note", cause: "person" }] }) };
  const r = await runChecks("Worked on: x.", { pii, rules: removesNothing });
  assert.equal(r.status, "could_not_finish");
  assert.equal(r.status === "could_not_finish" && r.check, "pii");
});

test("both checks run again over the result until a run of each removes nothing", async () => {
  const note = "Worked on: the fetcher. The Acme rollout.\nLearned: backoff. Jane Roe said so.\nStuck on: nothing.";
  // The Rules check's removal reveals nothing new here, but every pass reruns both.
  const pii = removing(["Jane Roe"], "person");
  const rules = removing(["Acme"], "rules");
  const r = await runChecks(note, { pii, rules });
  assert.equal(r.status, "passed");
  if (r.status !== "passed") return;
  assert.equal(r.text, "Worked on: the fetcher.\nLearned: backoff.\nStuck on: nothing.");
  assert.equal(r.removed, true);
  assert.deepEqual(r.runs, [
    { check: "pii", removals: [{ part: "Learned", cause: "person", count: 1 }] },
    { check: "rules", removals: [{ part: "Worked on", cause: "rules", count: 1 }] },
    { check: "pii", removals: [] },
    { check: "rules", removals: [] },
  ]);
  // The Rules check reads what the PII check left.
  assert.ok(!rules.seen[0]!.includes("Jane Roe"));
  const clean = await runChecks("Worked on: x.", { pii: removesNothing, rules: removesNothing });
  assert.deepEqual(clean, { status: "passed", text: "Worked on: x.", removed: false, runs: [{ check: "pii", removals: [] }, { check: "rules", removals: [] }] });
});

test("checks that remove everything leave an empty note, which is not written", async () => {
  const r = await runChecks("Worked on: the Acme deal.", { pii: removesNothing, rules: removing(["Acme"]) });
  assert.deepEqual(r, { status: "empty", runs: [{ check: "pii", removals: [] }, { check: "rules", removals: [{ part: "Worked on", cause: "rules", count: 1 }] }] });
});

test("the code step: secrets named by type with no characters of them, and no model sees them", async () => {
  const key = ["sk", "proj", "abcdefghijklmnop1234567890"].join("-");
  const note = `Worked on: rotating the staging key ${key} after the leak. Then the docs.\nLearned: card 4111 1111 1111 1111 is a test number.`;
  const pii = removing([]);
  const r = await runChecks(note, { pii, rules: removesNothing });
  assert.equal(r.status, "passed");
  if (r.status !== "passed") return;
  assert.equal(r.text, "Worked on: Then the docs.");
  assert.deepEqual(r.runs[0], {
    check: "pii",
    removals: [
      { part: "Worked on", cause: "detector", detector: "API key or token", count: 1 },
      { part: "Learned", cause: "detector", detector: "payment card number", count: 1 },
    ],
  });
  assert.ok(!JSON.stringify(r.runs).includes("4111") && !JSON.stringify(r.runs).includes("sk-"));
  assert.ok(!pii.seen.some((v) => v.includes(key) || v.includes("4111")), "the model reads what code left");
  const types = (t: string) => findDetected(t).map((f) => f.type);
  assert.deepEqual(types(`key AKIA${"ABCDEFGHIJKLMNOP"} here`), ["API key or token"]);
  assert.deepEqual(types("-----BEGIN RSA PRIVATE KEY-----\nMIIB\n-----END RSA PRIVATE KEY-----"), ["private key"]);
  assert.deepEqual(types("postgres://app:hunter2@db.example.org/main"), ["connection string", "email address"], "both read it; both are removed");
  assert.deepEqual(types("the build at 2f1c0a9 passed and a1b2c3d4e5f60718293a4b5c6d7e8f9012345678 too"), [], "a sha is not a secret");
});

test("the deny list in the code step matches as the node's backstop does, and never a circle name", () => {
  const entries = readDenyList([
    { id: "1", kind: "name", value: "Jane Roe" },
    { id: "2", kind: "domain", value: "acme.example" },
    { id: "3", kind: "id", value: "PRJ-42" },
    { id: "4", kind: "pattern", value: "secret-[0-9]+" },
    { id: "5", kind: "name", value: "Athena" },
    { id: "6", kind: "pattern", value: "([" },
    { id: "7", kind: "colour", value: "red" },
  ]);
  assert.equal(entries.length, 6, "an entry of no known kind is left out");
  const hits = (t: string) => findDenied(t, entries, ["Athena"]).map((f) => t.slice(f.start, f.end));
  assert.deepEqual(hits("Met jane roe at mail.ACME.example about prj-42 and Secret-7; Athena replied."), ["jane roe", "ACME.example", "prj-42", "Secret-7"]);
  assert.deepEqual(hits("Jane Roesmith and PRJ-420 are other words"), [], "a name or id matches as a whole word");
  const note = "Worked on: the fetcher.\nLearned: what Jane Roe said.";
  const r = removeSpans(note, findDenied(note, entries).map((f) => ({ ...f, cause: "deny_list" as const })));
  assert.deepEqual(r, { text: "Worked on: the fetcher.", removals: [{ part: "Learned", cause: "deny_list", count: 1 }] });
});

test("the Rules check deletes only what a line says to leave out; a line on how a note reads guides the writer only", () => {
  const system = buildSystemPrompt(readFileSync(RULES_CHECK_PROMPT_FILE, "utf8"), "", "Never name a customer.", "Name a fix by what it changes, not by its ticket.");
  assert.match(system, /You only find what a line says to LEAVE OUT\./);
  assert.match(system, /A line that says how\na note should READ .* guides the writer only and is never a reason to remove anything/s);
  assert.match(system, /When you cannot tell which a line is, it guides the writer\./);
  assert.ok(system.includes("Never name a customer.") && system.includes("Name a fix by what it changes"));
});
