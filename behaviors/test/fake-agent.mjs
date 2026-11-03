#!/usr/bin/env node
// A fake Codex, or a fake typed-path agent, for the tests: it answers from a recorded fixture and
// never calls a model. Called as `exec ... -` it is Codex: the system prompt is the
// `developer_instructions` config value, the data is stdin, and it streams `--json` events (a warning
// item, then the answer as the last agent_message). Called any other way it is a typed path: the
// prompt is its one argument and the answer is its stdout.
// Called as `debug models` it prints a model catalog in Codex's shape, or exits 1 with
// FAKE_NO_CATALOG set, and records nothing.
// FAKE_FIXTURE: file whose text is the answer; FAKE_EXIT: exit code; FAKE_FAIL: a Codex run fails
// its turn with this message; FAKE_LOG: where to record argv, cwd, stdin and the model catalog the
// run was given. A run whose system prompt is the PII check's or the Rules check's answers
// {"remove": []}.
import { appendFileSync, readFileSync } from "node:fs";

if (process.argv[2] === "debug" && process.argv[3] === "models") {
  if (process.env.FAKE_NO_CATALOG) process.exit(1);
  const model = (slug, extra) => ({ slug, tool_mode: "code_mode_only", experimental_supported_tools: ["clock"], apply_patch_tool_type: "freeform", multi_agent_version: "v2", shell_type: "unified_exec", ...extra });
  process.stdout.write(JSON.stringify({ models: [model("fake-1", {}), { slug: "fake-old", shell_type: "unified_exec" }] }));
  process.exit(0);
}

let stdin = "";
process.stdin.setEncoding("utf8");
for await (const chunk of process.stdin) stdin += chunk;
const env = process.env;
const argv = process.argv.slice(2);
const codex = argv[0] === "exec";
const instructions = argv.find((a) => a.startsWith("developer_instructions="));
const system = codex ? (instructions ? JSON.parse(instructions.slice("developer_instructions=".length)) : "") : (argv[0] ?? "");
const check = system.startsWith("You are the PII check") || system.startsWith("You are the Rules check");
const catalogArg = argv.find((a) => a.startsWith("model_catalog_json="));
const catalogPath = catalogArg ? JSON.parse(catalogArg.slice("model_catalog_json=".length)) : undefined;
const catalog = catalogPath ? JSON.parse(readFileSync(catalogPath, "utf8")) : undefined;
if (env.FAKE_LOG) appendFileSync(env.FAKE_LOG, JSON.stringify({ argv, cwd: process.cwd(), stdin, system, check, catalogPath, catalog }) + "\n");
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
