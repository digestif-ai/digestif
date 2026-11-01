#!/usr/bin/env node
// digestif-write: the digest lines on stdin, the note on stdout. The node's DIGESTIF_WRITER
// contract: exit 0 with a non-empty note, non-zero otherwise. See behaviors/README.md.
import { readFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { parseArgs } from "node:util";
import { DEFAULT_MAX_BUDGET_USD, DEFAULT_QUIET_MS, fetchContext, writeNote } from "../src/writer.ts";

const usage = `usage: digestif-write [--brief <file>] [--rules <file>] [--harness <path>]
                      [--quiet-seconds <n>] [--max-budget-usd <n>] < digest

  --brief, --rules     files holding the member's brief and rules; used when DIGESTIF_NODE and
                       DIGESTIF_SESSION are not both set (when they are, the node's local API is read)
  --harness            the harness binary (default: claude on PATH)
  --quiet-seconds      kill the harness as hung once it writes nothing for this long, not counting
                       time the machine sleeps (default ${DEFAULT_QUIET_MS / 1000})
  --max-budget-usd     the harness's spend cap for the run (default ${DEFAULT_MAX_BUDGET_USD})

DIGESTIF_WRITER_TASK=brief drafts a first brief from the card and source lines instead of the note.

Exit 0 with the note on stdout; 1 when no note came (failure, hung, empty answer); 4 when the
harness has no login; 2 on bad usage.`;

async function main(): Promise<number> {
  let args;
  try {
    args = parseArgs({
      options: {
        brief: { type: "string" },
        rules: { type: "string" },
        harness: { type: "string" },
        "quiet-seconds": { type: "string" },
        "max-budget-usd": { type: "string" },
        help: { type: "boolean", short: "h" },
      },
      allowPositionals: false,
    }).values;
  } catch (e) {
    console.error(`digestif-write: ${(e as Error).message}\n${usage}`);
    return 2;
  }
  if (args.help) {
    console.log(usage);
    return 0;
  }
  const quiet = args["quiet-seconds"] === undefined ? DEFAULT_QUIET_MS / 1000 : Number(args["quiet-seconds"]);
  const budget = args["max-budget-usd"] === undefined ? DEFAULT_MAX_BUDGET_USD : Number(args["max-budget-usd"]);
  if (!(quiet > 0) || !(budget > 0)) {
    console.error(`digestif-write: the quiet time and the budget are positive numbers\n${usage}`);
    return 2;
  }
  const taskName = process.env["DIGESTIF_WRITER_TASK"] ?? "";
  if (!["", "note", "brief"].includes(taskName)) {
    console.error(`digestif-write: DIGESTIF_WRITER_TASK is "note" or "brief", not ${JSON.stringify(taskName)}`);
    return 2;
  }
  const task = taskName === "brief" ? "brief" : "note";
  let brief = "";
  let rules = "";
  try {
    const node = process.env["DIGESTIF_NODE"];
    const session = process.env["DIGESTIF_SESSION"];
    if (node && session) ({ brief, rules } = await fetchContext({ node, session }));
    else {
      if (args.brief !== undefined) brief = await readFile(args.brief, "utf8");
      if (args.rules !== undefined) rules = await readFile(args.rules, "utf8");
    }
  } catch (e) {
    console.error(`digestif-write: ${(e as Error).message}`);
    return 2;
  }
  const lines = readFileSync(0, "utf8").split("\n").filter((l) => l.trim() !== "");
  if (lines.length === 0) {
    console.error("digestif-write: no digest lines on stdin");
    return 1;
  }
  const r = await writeNote(lines, {
    ...(args.harness === undefined ? {} : { harness: args.harness }),
    quietMs: quiet * 1000,
    maxBudgetUsd: budget,
    brief,
    rules,
    task,
  });
  switch (r.status) {
    case "note":
      process.stdout.write(r.note + "\n");
      return 0;
    case "signed_out":
      console.error("digestif-write: the harness has no login");
      return 4;
    case "hung":
      console.error(`digestif-write: the harness wrote nothing for ${r.quietMs / 1000} seconds`);
      return 1;
    case "empty":
      console.error("digestif-write: the harness answered nothing");
      return 1;
    case "failed":
      console.error(`digestif-write: ${r.message}`);
      return 1;
  }
}

process.exitCode = await main();
