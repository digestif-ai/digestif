#!/usr/bin/env node
// digestif-read: the read hook as the node's behavior (`digestif behavior set read <path>`). No
// arguments; one JSON context on stdin. Exits 0 once the feed is read and recorded. See behaviors/README.md.
import { readFileSync } from "node:fs";
import { endOnSigterm, parseReadContext, ReadContextError, runRead } from "../src/read.ts";

async function main(): Promise<number> {
  if (process.argv.length > 2) {
    console.error("digestif-read: takes no arguments; the node hands it a JSON context on stdin");
    return 2;
  }
  endOnSigterm();
  let ctx;
  try {
    ctx = parseReadContext(readFileSync(0, "utf8"));
  } catch (e) {
    if (!(e instanceof ReadContextError)) throw e;
    console.error(`digestif-read: ${e.message}`);
    return 2;
  }
  return runRead({ ctx });
}

process.exitCode = await main();
