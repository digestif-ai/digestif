#!/usr/bin/env node
// digestif-nightly: one firing of the nightly run. Safe to call as often as you like: it does
// what is due for the clock, once per local date. See behaviors/README.md.
import { readFile } from "node:fs/promises";
import { parseArgs } from "node:util";
import { holdAwake } from "../src/awake.ts";
import { runHook } from "../src/hook.ts";
import { defaultStateDir, nightly, MINUTE_MAX, MINUTE_MIN } from "../src/nightly.ts";
import { parseSelection } from "../src/sources.ts";
import { fetchContext } from "../src/writer.ts";

const usage = `usage: digestif-nightly --sources <file> [--state-dir <dir>] [--minute <${MINUTE_MIN}..${MINUTE_MAX}>]
                         [--node <digestif>] [--harness <path>] [--brief <file>] [--rules <file>]
                         [--allow <name>]... [--home <dir>] [--dry-run] [--now <local time>]

  --sources     the selection, as for digestif-extract
  --state-dir   where nightly.json and logs/ live (default: behaviors/ in the node's data directory)
  --minute      the fixed minute, minutes after local midnight; used once, when there is no state yet
  --node        the node binary (default: digestif on PATH)
  --harness, --brief, --rules   as for digestif-write
  --allow       a member's or agent's name the PII screen allows; repeatable
  --dry-run     run the pipeline now, print the note, post nothing, record nothing
  --now         pretend it is this local time (YYYY-MM-DDTHH:MM), for tests

Exits 0 unless a run failed (1) or the usage is wrong (2). "Not due" and "already done" are 0.`;

async function main(): Promise<number> {
  // The node's hook: no flags, one JSON handoff on stdin (src/hook.ts).
  if (process.env["DIGESTIF_HOOK"] !== undefined) {
    if (process.argv.length > 2) {
      console.error("digestif-nightly: in hook mode there are no flags; the handoff is on stdin");
      return 2;
    }
    return runHook(await readStdin());
  }
  let args;
  try {
    args = parseArgs({
      options: {
        sources: { type: "string" },
        "state-dir": { type: "string" },
        minute: { type: "string" },
        node: { type: "string" },
        harness: { type: "string" },
        brief: { type: "string" },
        rules: { type: "string" },
        allow: { type: "string", multiple: true },
        home: { type: "string" },
        "dry-run": { type: "boolean" },
        now: { type: "string" },
        help: { type: "boolean", short: "h" },
      },
      allowPositionals: false,
    }).values;
  } catch (e) {
    console.error(`digestif-nightly: ${(e as Error).message}\n${usage}`);
    return 2;
  }
  if (args.help) {
    console.log(usage);
    return 0;
  }
  if (args.sources === undefined) {
    console.error(`digestif-nightly: --sources is required\n${usage}`);
    return 2;
  }
  try {
    const selection = parseSelection(JSON.parse(await readFile(args.sources, "utf8")));
    const now = args.now === undefined ? new Date() : new Date(args.now);
    if (Number.isNaN(now.getTime())) throw new Error(`not a time: ${args.now}`);
    const node = process.env["DIGESTIF_NODE"];
    const session = process.env["DIGESTIF_SESSION"];
    if (!args["dry-run"]) holdAwake();
    const writer = {
      ...(args.harness === undefined ? {} : { harness: args.harness }),
      ...(args.brief === undefined ? {} : { brief: await readFile(args.brief, "utf8") }),
      ...(args.rules === undefined ? {} : { rules: await readFile(args.rules, "utf8") }),
    };
    const r = await nightly({
      stateDir: args["state-dir"] ?? defaultStateDir(),
      selection,
      now,
      ...(args.minute === undefined ? {} : { minute: Number(args.minute) }),
      ...(args.node === undefined ? {} : { node: args.node }),
      ...(args.home === undefined ? {} : { home: args.home }),
      ...(args["dry-run"] ? { dryRun: true } : {}),
      allow: args.allow ?? [],
      writer,
      ...(node && session ? { context: () => fetchContext({ node, session }) } : {}),
    });
    if (r.status === "dry_run") {
      if (r.note !== undefined) process.stdout.write(r.note + "\n");
      else console.error(r.refused === undefined ? "nothing to say" : `refused: ${r.refused}`);
      return 0;
    }
    console.error(`digestif-nightly: ${r.status} (${r.date})`);
    return r.status === "failed" ? 1 : 0;
  } catch (e) {
    console.error(`digestif-nightly: ${(e as Error).message}`);
    return 2;
  }
}

async function readStdin(): Promise<string> {
  let text = "";
  process.stdin.setEncoding("utf8");
  for await (const chunk of process.stdin) text += chunk;
  return text;
}

process.exitCode = await main();
