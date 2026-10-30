#!/usr/bin/env node
// A fake Claude Code for the tests: it answers from a recorded fixture and never calls a model.
// FAKE_FIXTURE: file whose text is printed; FAKE_EXIT: exit code; FAKE_SLEEP_MS: hang first;
// FAKE_LOG: where to record argv, cwd, stdin, pid and whether an API key reached it.
import { appendFileSync, readFileSync } from "node:fs";

let stdin = "";
process.stdin.setEncoding("utf8");
for await (const chunk of process.stdin) stdin += chunk;
const env = process.env;
if (env.FAKE_LOG) {
  appendFileSync(
    env.FAKE_LOG,
    JSON.stringify({ argv: process.argv.slice(2), cwd: process.cwd(), stdin, pid: process.pid, apiKey: env.ANTHROPIC_API_KEY !== undefined }) + "\n",
  );
}
if (env.FAKE_SLEEP_MS) await new Promise((r) => setTimeout(r, Number(env.FAKE_SLEEP_MS)));
if (env.FAKE_FIXTURE) process.stdout.write(readFileSync(env.FAKE_FIXTURE, "utf8"));
process.exit(Number(env.FAKE_EXIT ?? 0));
