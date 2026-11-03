#!/usr/bin/env node
// A fake Codex, or a fake typed-path agent, for the tests: it answers from a recorded fixture and
// never calls a model. Called as `exec ... -` it is Codex: the system prompt is the
// `developer_instructions` config value, the data is stdin, and it streams `--json` events (a warning
// item, then the answer as the last agent_message). Called any other way it is a typed path: the
// prompt is its one argument and the answer is its stdout.
// FAKE_FIXTURE: file whose text is the answer; FAKE_EXIT: exit code; FAKE_FAIL: a Codex run fails
// its turn with this message; FAKE_LOG: where to record argv, cwd and stdin. A run whose system
// prompt is the PII check's or the Rules check's answers {"remove": []}.
import { appendFileSync, readFileSync } from "node:fs";

let stdin = "";
process.stdin.setEncoding("utf8");
for await (const chunk of process.stdin) stdin += chunk;
const env = process.env;
const argv = process.argv.slice(2);
const codex = argv[0] === "exec";
const instructions = argv.find((a) => a.startsWith("developer_instructions="));
const system = codex ? (instructions ? JSON.parse(instructions.slice("developer_instructions=".length)) : "") : (argv[0] ?? "");
const check = system.startsWith("You are the PII check") || system.startsWith("You are the Rules check");
if (env.FAKE_LOG) appendFileSync(env.FAKE_LOG, JSON.stringify({ argv, cwd: process.cwd(), stdin, system, check }) + "\n");
const text = check ? '{"remove": []}' : env.FAKE_FIXTURE ? readFileSync(env.FAKE_FIXTURE, "utf8") : "";
const code = Number(env.FAKE_EXIT ?? 0);
if (!codex) {
  process.stdout.write(text);
  process.exit(code);
}
const event = (e) => process.stdout.write(JSON.stringify(e) + "\n");
event({ type: "thread.started", thread_id: "t" });
event({ type: "turn.started" });
event({ type: "item.completed", item: { id: "item_0", type: "error", message: "Codex is ignoring 1 unrecognized configuration setting." } });
if (env.FAKE_FAIL) {
  event({ type: "turn.failed", error: { message: env.FAKE_FAIL } });
  process.exit(code || 1);
}
event({ type: "item.completed", item: { id: "item_1", type: "agent_message", text: "Drafting the note." } });
event({ type: "item.completed", item: { id: "item_2", type: "agent_message", text } });
event({ type: "turn.completed", usage: {} });
process.exit(code);
