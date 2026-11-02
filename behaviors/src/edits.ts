// The member's edit of a note (DES-37265, Approve and Edit; Rules and Learnings): the node spawns
// the check hook with each edited version whose checks or Learnings update are due, and with the
// agent's own version when a check could not finish as it was written (One way a failure is
// reported): only its checks run again, never the writing. Both checks run on the member's text
// exactly as on the agent's, and the result goes back with `digestif note checked`. Once a version's checks have passed, the agent reads the diff between the
// version the member edited and the checked text, so nothing a check removed reaches Learnings, and
// hands Learnings back whole with `digestif learnings set`. A failed update is retried by the node,
// at most once an hour; the note never waits for it.

import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { modelPiiCheck, modelRulesCheck, runChecks, type ModelCheck } from "./checks.ts";
import type { DenyEntry } from "./deny.ts";
import { reportProblem, runNode } from "./nightly.ts";
import { askHarness, buildSystemPrompt, PROMPTS_DIR, type WriterOptions } from "./writer.ts";

/** One edited version the node handed over. */
export interface Edit {
  id: string;
  noteId: string;
  /** "agent" for the agent's own version, whose checks could not finish as it was written. */
  voice: "agent" | "person";
  /** The submitted words, or the checked text once only the Learnings update is owed. */
  text: string;
  checked: boolean;
  /** The checked text of the version the member edited. */
  editedText: string;
}

export const LEARNINGS_PROMPT_FILE = join(PROMPTS_DIR, "learnings.md");
/** The learnings model's answer when an edit teaches nothing. */
export const NO_CHANGE = "NO CHANGE";

/**
 * The edit as lines taken out (`- `) and put in (`+ `), from a longest common subsequence of the
 * lines, so a passage moved or kept reads as kept. Blank lines are not lessons and are left out.
 */
export function lineDiff(before: string, after: string): string {
  const a = before.split("\n");
  const b = after.split("\n");
  const n = a.length;
  const m = b.length;
  const lcs: number[][] = Array.from({ length: n + 1 }, () => new Array<number>(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      lcs[i]![j] = a[i] === b[j] ? lcs[i + 1]![j + 1]! + 1 : Math.max(lcs[i + 1]![j]!, lcs[i]![j + 1]!);
    }
  }
  const out: string[] = [];
  let i = 0;
  let j = 0;
  while (i < n || j < m) {
    if (i < n && j < m && a[i] === b[j]) {
      i++;
      j++;
    } else if (i < n && (j >= m || lcs[i + 1]![j]! >= lcs[i]![j + 1]!)) {
      if (a[i]!.trim() !== "") out.push(`- ${a[i]}`);
      i++;
    } else {
      if (b[j]!.trim() !== "") out.push(`+ ${b[j]}`);
      j++;
    }
  }
  return out.join("\n");
}

export type LearningsResult = { status: "updated"; text: string } | { status: "failed"; reason: string; signedOut?: boolean };

/** Asks the member's agent for Learnings, whole, after one edit; an empty diff teaches nothing. */
export async function updateLearnings(
  edit: { edited: string; checked: string },
  context: { learnings: string; rules: string },
  options: Pick<WriterOptions, "harness" | "quietMs" | "now" | "maxBudgetUsd"> & { prompt?: string } = {},
): Promise<LearningsResult> {
  const diff = lineDiff(edit.edited, edit.checked);
  if (diff === "") return { status: "updated", text: context.learnings };
  const template = options.prompt ?? (await readFile(LEARNINGS_PROMPT_FILE, "utf8"));
  const system = buildSystemPrompt(template, "", context.rules, context.learnings);
  const r = await askHarness(system, `The edit, as data:\n\n${diff}\n`, options);
  if (r.status === "note") return { status: "updated", text: r.note.trim() === NO_CHANGE ? context.learnings : r.note };
  if (r.status === "signed_out") return { status: "failed", reason: "the agent is signed out", signedOut: true };
  if (r.status === "hung") return { status: "failed", reason: `the agent wrote nothing for ${Math.round(r.quietMs / 60_000)} minutes` };
  if (r.status === "failed") return { status: "failed", reason: r.message };
  return { status: "failed", reason: "the agent gave no answer" };
}

export interface EditsOptions {
  edits: Edit[];
  /** The node binary. */
  node: string;
  allow?: string[];
  deny?: DenyEntry[];
  rules?: string;
  learnings?: string;
  writer?: Pick<WriterOptions, "harness" | "quietMs" | "now" | "maxBudgetUsd">;
  /** The checks' models, for tests; by default the member's harness answers them. */
  pii?: ModelCheck;
  rulesCheck?: ModelCheck;
  /** The Learnings update, for tests. */
  learn?: typeof updateLearnings;
  /** Whether the member saved auto approval, read when the agent's own version passes. */
  autoApprove?: () => Promise<boolean>;
  log?: (line: string) => void;
}

/** Checks each edit and updates Learnings from each checked one. Answers how many steps failed. */
export async function checkEdits(o: EditsOptions): Promise<number> {
  const say = o.log ?? ((line: string) => console.error(`digestif-check: ${line}`));
  const harness = o.writer ?? {};
  let learnings = o.learnings ?? "";
  let failed = 0;
  for (const e of o.edits) {
    let checkedText = e.text;
    if (!e.checked) {
      const r = await runChecks(e.text, {
        allow: o.allow ?? [],
        deny: o.deny ?? [],
        pii: o.pii ?? modelPiiCheck(harness),
        rules: o.rulesCheck ?? modelRulesCheck({ ...harness, rules: o.rules ?? "", learnings }),
      });
      const runs = JSON.stringify(r.runs);
      if (r.status === "could_not_finish") {
        say(`${e.id}: the ${r.check} check could not finish: ${r.reason}`);
        const h = await runNode(o.node, ["note", "checked", e.id, "--could-not-finish", r.check, "--checks", runs, ...(r.signedOut ? ["--signed-out"] : [])]);
        if (h.code !== 0) say(`${e.id}: digestif note checked exited ${h.code}: ${h.stderr.trim().slice(0, 200)}`);
        failed++;
        continue;
      }
      // An edit the checks emptied is still the member's result to see; there is nothing to approve.
      // The agent's own version emptied is no note, and the node writes none.
      checkedText = r.status === "passed" ? r.text : "";
      const removed = r.status === "empty" || r.removed;
      // The agent approves its own version only now, when auto approval is saved.
      const approve = e.voice === "agent" && checkedText !== "" && o.autoApprove ? await o.autoApprove().catch(() => false) : false;
      const h = await runNode(
        o.node,
        ["note", "checked", e.id, "--text", "-", "--checks", runs, ...(removed ? ["--removed"] : []), ...(approve ? ["--approve"] : [])],
        checkedText + "\n",
      );
      if (h.code !== 0) {
        say(`${e.id}: digestif note checked exited ${h.code}: ${h.stderr.trim().slice(0, 200)}`);
        failed++;
        continue;
      }
      say(`${e.id}: checks passed${removed ? ", something was removed" : ""}`);
    }
    // Learnings are read from the member's edits; the agent's own words teach nothing.
    if (e.voice === "agent") continue;
    const learn = o.learn ?? updateLearnings;
    const l = await learn({ edited: e.editedText, checked: checkedText }, { learnings, rules: o.rules ?? "" }, harness);
    if (l.status === "failed") {
      say(`${e.id}: Learnings were not updated: ${l.reason}`);
      const err = await reportProblem(o.node, "learnings", l.signedOut ? "signed_out" : "model_unavailable");
      if (err !== undefined) say(`${e.id}: the problem was not recorded: ${err}`);
      failed++;
      continue;
    }
    const h = await runNode(o.node, ["learnings", "set", "--version", e.id, "--text", "-"], l.text + "\n");
    if (h.code !== 0) {
      say(`${e.id}: digestif learnings set exited ${h.code}: ${h.stderr.trim().slice(0, 200)}`);
      failed++;
      continue;
    }
    learnings = l.text;
    say(`${e.id}: Learnings updated`);
  }
  return failed;
}
