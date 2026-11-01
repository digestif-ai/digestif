#!/usr/bin/env node
// A fake Claude Code for the tests: it answers from a recorded fixture and never calls a model.
// It streams the way `--output-format stream-json --verbose` does: an init event, the answer as
// partial-message events, then one result event carrying the fixture's text.
// FAKE_FIXTURE: file whose text is the answer; FAKE_EXIT: exit code (non-zero marks the result an
// error); FAKE_SLEEP_MS: go quiet this long after the init event; FAKE_TRICKLE_MS: during that wait,
// write a progress event this often instead of staying quiet; FAKE_LOG: where to record argv, cwd,
// stdin, pid, the grandchild's pid (FAKE_GRANDCHILD: start a sleeping child of its own, as a harness
// with helpers would) and which secrets reached it. A run whose system prompt is the
// business-information screen's answers FAKE_SCREEN_FIXTURE's text, or {"hold": false} without one.
import { spawn } from "node:child_process";
import { appendFileSync, readFileSync } from "node:fs";
import { clearInterval, setInterval } from "node:timers";

let stdin = "";
process.stdin.setEncoding("utf8");
for await (const chunk of process.stdin) stdin += chunk;
const env = process.env;
const argv = process.argv.slice(2);
const screen = (argv[argv.indexOf("--system-prompt") + 1] ?? "").startsWith("You are the business-information screen");
const grandchild = env.FAKE_GRANDCHILD ? spawn(process.execPath, ["-e", "setTimeout(() => {}, 60000)"], { stdio: "inherit" }).pid : undefined;
if (env.FAKE_LOG) {
  appendFileSync(
    env.FAKE_LOG,
    JSON.stringify({ argv, screen, cwd: process.cwd(), stdin, pid: process.pid, grandchild, apiKey: env.ANTHROPIC_API_KEY !== undefined, session: env.DIGESTIF_SESSION !== undefined }) + "\n",
  );
}
const event = (e) => process.stdout.write(JSON.stringify(e) + "\n");
event({ type: "system", subtype: "init", tools: [] });
if (env.FAKE_SLEEP_MS) {
  const trickle = env.FAKE_TRICKLE_MS ? setInterval(() => event({ type: "stream_event", event: { type: "ping" } }), Number(env.FAKE_TRICKLE_MS)) : undefined;
  await new Promise((r) => setTimeout(r, Number(env.FAKE_SLEEP_MS)));
  clearInterval(trickle);
}
const text = screen
  ? env.FAKE_SCREEN_FIXTURE
    ? readFileSync(env.FAKE_SCREEN_FIXTURE, "utf8")
    : '{"hold": false}'
  : env.FAKE_FIXTURE
    ? readFileSync(env.FAKE_FIXTURE, "utf8")
    : "";
const code = Number(env.FAKE_EXIT ?? 0);
for (const line of text.split("\n")) event({ type: "stream_event", event: { type: "content_block_delta", delta: { type: "text_delta", text: line } } });
event({ type: "result", subtype: "success", is_error: code !== 0, result: text });
process.exit(code);
