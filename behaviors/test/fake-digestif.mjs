#!/usr/bin/env node
// A fake `digestif` for the tests: it records its arguments and stdin, one JSON line per call.
import { appendFileSync } from "node:fs";

let stdin = "";
process.stdin.setEncoding("utf8");
for await (const chunk of process.stdin) stdin += chunk;
appendFileSync(process.env.FAKE_DIGESTIF_LOG, JSON.stringify({ args: process.argv.slice(2), stdin }) + "\n");
process.exit(Number(process.env.FAKE_DIGESTIF_EXIT ?? 0));
