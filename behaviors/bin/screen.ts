#!/usr/bin/env node
// digestif-screen: reads a note on stdin, runs the PII detectors, prints a JSON verdict on stdout
// and exits 0 (ok) or 3 (a rule tripped). See behaviors/README.md.
import { readFileSync } from "node:fs";
import { parseArgs } from "node:util";
import { screenPii } from "../src/pii.ts";

const usage = `usage: digestif-screen [--allow <name>]... < note

  --allow <name>   a member's or agent's name the circle allows; repeatable

Reads the note on stdin. Prints {"ok":true} and exits 0, or {"ok":false,"rule":"…"} and exits 3,
naming the rule and never the text. Exits 2 on bad usage.`;

function main(): number {
  let args;
  try {
    args = parseArgs({
      options: { allow: { type: "string", multiple: true }, help: { type: "boolean", short: "h" } },
      allowPositionals: false,
    }).values;
  } catch (e) {
    console.error(`digestif-screen: ${(e as Error).message}\n${usage}`);
    return 2;
  }
  if (args.help) {
    console.log(usage);
    return 0;
  }
  const note = readFileSync(0, "utf8");
  const verdict = screenPii(note, args.allow ?? []);
  process.stdout.write(JSON.stringify(verdict) + "\n");
  return verdict.ok ? 0 : 3;
}

process.exitCode = main();
