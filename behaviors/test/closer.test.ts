// The question closer (src/closer.ts): the model's answer read as a verdict or as nothing, the
// question closed naming the answer it numbered, and every failure leaving the question open
// without failing the note. Every value is made up.
import assert from "node:assert/strict";
import { test } from "node:test";
import { closeQuestions, closerInput, readCloserAnswer, type Ask, type OpenQuestion, type QuestionsAccess } from "../src/closer.ts";
import { ALWAYS_ON_RULES, type WriteResult } from "../src/writer.ts";

const question = (id: string, answers: string[]): OpenQuestion => ({
  id,
  title: "Has anyone used a fake clock for timer tests?",
  detail: "",
  asked_at: "2026-11-05T07:00:00Z",
  answers: answers.map((text, i) => ({ hash: `sha256:${id}-${i + 1}`, author: { name: `Member ${i + 1}` }, text, created_at: "2026-11-05T09:00:00Z" })),
});

const node = (questions: OpenQuestion[] | Error): QuestionsAccess & { closed: [string, string][] } => {
  const closed: [string, string][] = [];
  return {
    closed,
    list: async () => {
      if (questions instanceof Error) throw questions;
      return questions;
    },
    close: async (id, answer) => {
      closed.push([id, answer]);
    },
  };
};

const answering = (answers: Record<string, WriteResult>): Ask & { seen: { system: string; input: string }[] } => {
  const seen: { system: string; input: string }[] = [];
  const ask = async (system: string, input: string) => {
    seen.push({ system, input });
    const id = Object.keys(answers).find((k) => input.includes(`sha256:${k}`) || input.includes(k));
    return answers[id ?? ""] ?? { status: "note" as const, note: '{"close": false}' };
  };
  return Object.assign(ask, { seen });
};

const logs = () => {
  const lines: string[] = [];
  return { lines, log: async (m: string) => void lines.push(m) };
};

test("the model's answer is a verdict naming one of the answers, or nothing", () => {
  assert.deepEqual(readCloserAnswer('{"close": false}', 2), { close: false });
  assert.deepEqual(readCloserAnswer('Sure. {"close": true, "answer": 2}', 2), { close: true, answer: 2 });
  for (const bad of ['{"close": true}', '{"close": true, "answer": 3}', '{"close": true, "answer": 0}', '{"close": true, "answer": 1.5}', '{"close": "yes"}', "close it", ""]) {
    assert.equal(readCloserAnswer(bad, 2), undefined, bad);
  }
});

test("the input carries the question, its answers numbered from 1 and the record, as data", () => {
  const input = closerInput(question("q1", ["Inject one at startup.", "Use faketime."]), ["commit: app abc: Inject a fake clock into the timer tests"]);
  assert.match(input, /^The question, as data:\n\nHas anyone used a fake clock/);
  assert.match(input, /1\. Member 1: Inject one at startup\.\n2\. Member 2: Use faketime\./);
  assert.match(input, /The person's record since, as data:\n\ncommit: app abc: Inject a fake clock/);
});

test("a question the record shows unblocked closes naming its answer; the rest stay open", async () => {
  const n = node([question("q1", ["Inject one at startup.", "Use faketime."]), question("q2", ["Ask the relay team."]), question("q3", [])]);
  const ask: Ask = async (_system, input) =>
    input.includes("Use faketime.") ? { status: "note", note: '{"close": true, "answer": 2}' } : { status: "note", note: '{"close": false}' };
  const seen: string[] = [];
  const { lines, log } = logs();
  const r = await closeQuestions(["commit: app abc: Run the timer tests under faketime"], {
    questions: n,
    ask: async (s, i) => {
      seen.push(s);
      return ask(s, i);
    },
    log,
  });
  assert.deepEqual(r, { read: 2, closed: 1 }, "a question with no answer is not read");
  assert.deepEqual(n.closed, [["q1", "sha256:q1-2"]]);
  assert.ok(seen.every((s) => s.startsWith("You close one question") && s.includes(ALWAYS_ON_RULES)), "the closer's prompt, with the always-on rule");
  assert.ok(lines.some((l) => l.includes("closed q1")));
});

test("nothing the closer cannot do closes a question or fails the run", async () => {
  const { lines, log } = logs();
  assert.deepEqual(await closeQuestions([], { questions: node(new Error("node down")), ask: answering({}), log }), { read: 0, closed: 0 });
  assert.match(lines[0]!, /could not be read: node down/);

  const n = node([question("q1", ["A."]), question("q2", ["B."])]);
  const r = await closeQuestions([], {
    questions: n,
    ask: async (_s, input) => (input.includes("A.") ? { status: "signed_out" } : { status: "note", note: "I think so" }),
    log,
  });
  assert.deepEqual(r, { read: 2, closed: 0 });
  assert.deepEqual(n.closed, []);

  const refusing: QuestionsAccess = { list: async () => [question("q1", ["A."])], close: async () => Promise.reject(new Error("person closed it")) };
  assert.deepEqual(await closeQuestions([], { questions: refusing, ask: async () => ({ status: "note", note: '{"close": true, "answer": 1}' }), log }), { read: 1, closed: 0 });
  assert.ok(lines.some((l) => l.includes("could not be closed: person closed it")));

  const late = node([question("q1", ["A."])]);
  assert.deepEqual(await closeQuestions([], { questions: late, ask: answering({}), log, late: () => "the deadline is near" }), { read: 0, closed: 0 });
});
