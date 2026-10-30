#!/usr/bin/env node
// digestif-extract: the day's digest lines from the chosen sources, one per line on stdout, each
// prefixed by its kind (commit:, session:, prompt:), in the shape the node hands a DIGESTIF_WRITER
// on stdin. See behaviors/README.md.
import { readFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { parseArgs } from "node:util";
import { day, parseOffset, today } from "../src/day.ts";
import { extract, render } from "../src/extract.ts";
import { chosen, parseSelection } from "../src/sources.ts";

const usage = `usage: digestif-extract --sources <file> [--date YYYY-MM-DD] [--offset +HH:MM]

  --sources <file>   the selection: the node's [source] list (GET /sources, with selected flags),
                     or { "sources": [source], "form": sources_form }; "-" reads stdin
  --date             the local date to extract; today when absent
  --offset           read the day in this fixed UTC offset instead of the machine's zone
  --home <dir>       what ~ in source paths expands to; the user's home when absent

Prints the digest lines, one per item, as "kind: text". Exits 0 with the lines, 2 on bad usage.`;

async function main(): Promise<number> {
  let args;
  try {
    args = parseArgs({
      options: {
        sources: { type: "string" },
        date: { type: "string" },
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
    const d = day(args.date ?? today(), args.offset === undefined ? undefined : parseOffset(args.offset));
    const lines = await extract(chosen(sources, form), d, args.home === undefined ? {} : { home: args.home });
    for (const line of render(lines)) process.stdout.write(line + "\n");
    return 0;
  } catch (e) {
    console.error(`digestif-extract: ${(e as Error).message}`);
    return 2;
  }
}

process.exitCode = await main();
