// The member's edit of a note (DES-37265, Approve and Edit; Rules and Learnings): both checks run on
// the member's text exactly as on the agent's, the result goes back with `digestif note checked`,
// and Learnings are updated from the diff of the checked text, never from what a check removed.
// Every value is made up.
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { removesNothing, type ModelCheck } from "../src/checks.ts";
import { checkEdits, lineDiff, updateLearnings, type Edit } from "../src/edits.ts";

const dir = mkdtempSync(join(tmpdir(), "digestif-edits-"));
const node = join(import.meta.dirname, "fake-digestif.mjs");
after(() => rmSync(dir, { recursive: true, force: true }));

function calls(log: string): { args: string[]; stdin: string }[] {
  try {
    return readFileSync(log, "utf8")
      .trim()
      .split("\n")
      .filter((l) => l !== "")
      .map((l) => JSON.parse(l) as { args: string[]; stdin: string });
  } catch {
    return [];
  }
}

/** Runs checkEdits with the fake node recording into its own log. */
async function run(
  edits: Edit[],
  o: { rulesCheck?: ModelCheck; learn?: Parameters<typeof checkEdits>[0]["learn"]; learnings?: string; autoApprove?: boolean } = {},
) {
  const log = join(dir, `${Math.random().toString(36).slice(2)}.log`);
  process.env["FAKE_DIGESTIF_LOG"] = log;
  const lines: string[] = [];
  const failed = await checkEdits({
    edits,
    node,
    pii: removesNothing,
    rulesCheck: o.rulesCheck ?? removesNothing,
    learnings: o.learnings ?? "",
    learn: o.learn ?? (async (e, c) => ({ status: "updated", text: `${c.learnings}\nlearned from: ${lineDiff(e.edited, e.checked)}`.trim() })),
    log: (l) => lines.push(l),
    ...(o.autoApprove === undefined ? {} : { autoApprove: async () => o.autoApprove! }),
  });
  return { failed, calls: calls(log), lines };
}

const edit = (over: Partial<Edit> = {}): Edit => ({
  id: "v2",
  noteId: "n1",
  voice: "person",
  text: "Worked on: the fetcher.\nLearned: retries need a cap.",
  checked: false,
  editedText: "Worked on: the fetcher.\nLearned: retries.",
  ...over,
});

test("lineDiff: the lines taken out and put in, a kept line not at all", () => {
  assert.equal(lineDiff("a\nb\nc", "a\nB\nc"), "- b\n+ B");
  assert.equal(lineDiff("a\nb", "a\nb"), "");
  assert.equal(lineDiff("a", "a\n\nb"), "+ b", "a blank line is no lesson");
});

test("an edit's checks pass: the checked text goes back, then Learnings from its diff", async () => {
  const r = await run([edit()]);
  assert.equal(r.failed, 0);
  assert.deepEqual(r.calls[0]!.args.slice(0, 6), ["note", "checked", "v2", "--text", "-", "--checks"]);
  assert.ok(!r.calls[0]!.args.includes("--removed"));
  assert.equal(r.calls[0]!.stdin, "Worked on: the fetcher.\nLearned: retries need a cap.\n");
  assert.deepEqual(r.calls[1]!.args, ["learnings", "set", "v2", "--text", "-"]);
  assert.equal(r.calls[1]!.stdin, "learned from: - Learned: retries.\n+ Learned: retries need a cap.\n");
});

test("what a check removed is said with --removed, and never reaches Learnings", async () => {
  const rules: ModelCheck = {
    ask: async (v) => ({ status: "spans", spans: v.includes("Acme Corp") ? [{ text: "Acme Corp", cause: "rules" }] : [] }),
  };
  const r = await run([edit({ text: "Worked on: the fetcher.\nLearned: retries need a cap. Acme Corp asked for it." })], { rulesCheck: rules });
  assert.ok(r.calls[0]!.args.includes("--removed"));
  assert.equal(r.calls[0]!.stdin, "Worked on: the fetcher.\nLearned: retries need a cap.\n");
  assert.ok(!r.calls[1]!.stdin.includes("Acme"), "the diff is read from the checked text");
});

test("a check that could not finish is handed back by name, and Learnings wait", async () => {
  const down: ModelCheck = { ask: async () => ({ status: "could_not_finish", reason: "signed out", signedOut: true }) };
  const r = await run([edit()], { rulesCheck: down });
  assert.equal(r.failed, 1);
  assert.equal(r.calls.length, 1);
  assert.deepEqual(r.calls[0]!.args.slice(0, 5), ["note", "checked", "v2", "--could-not-finish", "rules"]);
  assert.ok(r.calls[0]!.args.includes("--signed-out"));
});

test("an edit already checked owes only its Learnings update; a failed one is left for the node to retry", async () => {
  const ok = await run([edit({ checked: true })]);
  assert.deepEqual(
    ok.calls.map((c) => c.args[0]),
    ["learnings"],
  );
  const failed = await run([edit({ checked: true })], { learn: async () => ({ status: "failed", reason: "the agent is signed out", signedOut: true }) });
  assert.equal(failed.failed, 1);
  assert.deepEqual(
    failed.calls.map((c) => c.args),
    [["problem", "report", "--job", "learnings", "--kind", "signed_out"]],
    "the failure is a problem in the one record",
  );
  assert.ok(failed.lines.some((l) => l.includes("Learnings were not updated")));
});

test("the agent's own version, whose checks could not finish, runs its checks alone: no Learnings, approved when auto approval is saved", async () => {
  const agent = edit({ id: "v1", voice: "agent", text: "Worked on: the fetcher.", editedText: "" });
  const waits = await run([agent]);
  assert.equal(waits.failed, 0);
  assert.equal(waits.calls.length, 1, "no Learnings from the agent's own words");
  assert.deepEqual(waits.calls[0]!.args.slice(0, 3), ["note", "checked", "v1"]);
  assert.ok(!waits.calls[0]!.args.includes("--approve"));
  const auto = await run([agent], { autoApprove: true });
  assert.ok(auto.calls[0]!.args.includes("--approve"), "the agent approves it");
  const emptied: ModelCheck = { ask: async (v) => ({ status: "spans", spans: [{ text: v, cause: "rules" }] }) };
  const none = await run([agent], { rulesCheck: emptied, autoApprove: true });
  assert.ok(!none.calls[0]!.args.includes("--approve"), "nothing to approve");
  assert.equal(none.calls[0]!.stdin, "\n");
});

test("updateLearnings: an edit that changed nothing keeps Learnings without asking the agent", async () => {
  const r = await updateLearnings({ edited: "same", checked: "same" }, { learnings: "Keep it short.", rules: "" }, { harness: "/nonexistent" });
  assert.deepEqual(r, { status: "updated", text: "Keep it short." });
});
