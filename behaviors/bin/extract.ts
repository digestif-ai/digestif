#!/usr/bin/env node
// digestif-extract: the record from the chosen sources, one item per line on stdout, as a note's
// work run reads it (commit:, session:, prompt:, a command source's label:). See behaviors/README.md.
import { readFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { parseArgs } from "node:util";
import { readRecord } from "../src/extract.ts";
import { parseOffset } from "../src/record.ts";
import { chosen, parseSelection } from "../src/sources.ts";

const usage = `usage: digestif-extract --sources <file> [--now <time>] [--offset +HH:MM] [--home <dir>]

  --sources <file>   the selection: the node's [source] list (GET /sources, with selected flags),
                     or { "sources": [source], "form": sources_form }; "-" reads stdin. A source
                     with a start (as the nightly hook's handoff carries) reads from it; with
                     none, every source reads the first note's reach
  --now              read the record as of this time (ISO 8601); now when absent
  --offset           a command source's --since in this fixed UTC offset instead of the machine's zone
  --home <dir>       what ~ in source paths expands to; the user's home when absent

Prints the record, one item per line, as "kind: text", oldest first. Exits 0 with the lines, 2 on
bad usage.`;

async function main(): Promise<number> {
  let args;
  try {
    args = parseArgs({
      options: {
        sources: { type: "string" },
        now: { type: "string" },
        offset: { type: "string" },
        home: { type: "string" },
        help: { type: "boolean", short: "h" },
      },
      allowPositionals: false,
    }).values;
  } catch (e) {
    console.error(`digestif-extract: ${(e as Error).message}\n${usage}`);
    return 2;
  }
  if (args.help) {
    console.log(usage);
    return 0;
  }
  if (args.sources === undefined) {
    console.error(`digestif-extract: --sources is required\n${usage}`);
    return 2;
  }
  try {
    const text = args.sources === "-" ? readFileSync(0, "utf8") : await readFile(args.sources, "utf8");
    const { sources, form } = parseSelection(JSON.parse(text));
    const now = args.now === undefined ? Date.now() : Date.parse(args.now);
    if (Number.isNaN(now)) throw new Error(`not a time: ${args.now}`);
    const picked = chosen(sources, form);
    const r = await readRecord(picked, {
      firstNote: !picked.some((s) => s.start !== undefined || (s.repositories ?? []).some((x) => x.start !== undefined)),
      now: () => now,
      ...(args.home === undefined ? {} : { home: args.home }),
      ...(args.offset === undefined ? {} : { utcOffsetMinutes: parseOffset(args.offset) }),
    });
    for (const line of r.lines) process.stdout.write(line + "\n");
    for (const f of r.failures) console.error(`digestif-extract: ${f}`);
    return 0;
  } catch (e) {
    console.error(`digestif-extract: ${(e as Error).message}`);
    return 2;
  }
}

process.exitCode = await main();
