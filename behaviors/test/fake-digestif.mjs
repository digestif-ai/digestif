#!/usr/bin/env node
// A fake `digestif` for the tests: it records its arguments and stdin, one JSON line per call.
// `digestif question list` answers FAKE_QUESTIONS (a JSON list), else no questions.
import { appendFileSync } from "node:fs";

let stdin = "";
process.stdin.setEncoding("utf8");
for await (const chunk of process.stdin) stdin += chunk;
appendFileSync(process.env.FAKE_DIGESTIF_LOG, JSON.stringify({ args: process.argv.slice(2), stdin }) + "\n");
const args = process.argv.slice(2);
if (args[0] === "question" && args[1] === "list") process.stdout.write(process.env.FAKE_QUESTIONS ?? "[]");
process.exit(Number(process.env.FAKE_DIGESTIF_EXIT ?? 0));
