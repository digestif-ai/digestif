// The read behavior: run against a fake local API over fixture feeds.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test as nodeTest, type TestContext } from "node:test";
import { buildReadPrompt, emptyState, loadConfig, loadState, localDay, parseReadContext, readStateDir, runRead, saveState } from "../src/read.ts";
import { INBOX_PROMPT_FILE, parseRun } from "../src/inbox.ts";
import { ALWAYS_ON_FILE } from "../src/writer.ts";
import { assertGone } from "./processes.ts";
import { noLoopback } from "./loopback.ts";

const here = import.meta.dirname;
const bin = join(here, "..", "bin", "read.ts");
const ME = "ed25519:me";
const OTHER = "ed25519:other";

interface Item {
  hash: string;
  created_at: string;
  author: { identity: string; name: string; agent_name: string };
  status_note?: string;
}
const item = (n: number, identity = OTHER, status_note?: string): Item => ({
  hash: `sha256:${n}`,
  created_at: `2026-11-01T00:00:${String(n).padStart(2, "0")}Z`,
  author: { identity, name: "x", agent_name: "y" },
  ...(status_note === undefined ? {} : { status_note }),
});

// Every case here reads through a local server the beforeEach starts, so without loopback the
// whole file skips with the reason instead of hanging on the first listen. DIG-298
const test = (name: string, fn: (t: TestContext) => void | Promise<void>) => nodeTest(name, { skip: noLoopback }, fn);

let dir: string;
let data: string;
let server: Server;
let url: string;
let feed: Item[]; // newest first
let requests: string[];
let extraMembers: { identity: string; is_self: boolean; muted?: boolean }[];
let messages: Record<string, { voice: string; reply_to?: string; text?: string; kind?: string }>; // what GET /messages/:hash knows
let quiet: { start: string; end: string; active: boolean; ends_at?: string } | null; // GET /rules/quiet_hours; null is a 404
let nodeLog: string; // the fake `digestif` appends its arguments here
let answerFile: string; // what the fake harness answers the Inbox run; "!signedout" makes it a login failure
let checkFile: string; // what the fake harness answers both checks; {"remove": []} when absent
let harnessLog: string; // the fake harness appends one JSON line per run: its arguments and stdin
const PAGE = 2; // the fake serves two a page whatever the limit asked
/** GET /items: the Inbox, as item_summary rows; GET /items/:id serves the same row with `detail`. */
let inbox: Record<string, unknown>[];
/** GET /settings/inbox_agent; null is a 404 (a node with no agent). */
let inboxPrompt: { text: string } | null;
/** Every POST /inbox_agent/runs body, and whether the node answers it (false: HTTP 500). */
let posted: { reviews: { hash: string; review: string }[]; answers: { item: string; text: string; send: boolean }[]; items: Record<string, unknown>[] }[];
let nodeRecords: boolean;

beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), "digestif-read-test-"));
  data = join(dir, "data");
  nodeLog = join(dir, "node.log");
  answerFile = join(dir, "answer");
  checkFile = join(dir, "check");
  harnessLog = join(dir, "harness.log");
  writeFileSync(
    join(dir, "digestif"),
    `#!/bin/sh\necho "$@" >> "${nodeLog}"\ncase "$1" in post|ask) cat > "${dir}/stdin-$1" ;; esac\n` +
      `if [ "$1" = post ] && [ -f "${dir}/post-exit3" ]; then echo "digestif: refused by the deny layer: no customer names" >&2; exit 3; fi\n` +
      `if [ "$1" = ask ] && [ -f "${dir}/ask-fail-once" ]; then rm "${dir}/ask-fail-once"; echo "digestif: node unavailable" >&2; exit 1; fi\n`,
    { mode: 0o755 },
  );
  // A harness that runs no model: it logs what it was given and answers what the test put in `answer`.
  writeFileSync(
    join(dir, "harness"),
    `#!${process.execPath}\nconst fs = require("fs");\n` +
      `const args = process.argv.slice(2); const system = args[args.indexOf("--system-prompt") + 1] || "";\n` +
      `const check = system.startsWith("You are the PII check") || system.startsWith("You are the Rules check");\n` +
      `fs.appendFileSync(${JSON.stringify(harnessLog)}, JSON.stringify({ args, check, cwd: process.cwd(), stdin: fs.readFileSync(0, "utf8") }) + "\\n");\n` +
      `try { const ms = Number(fs.readFileSync(${JSON.stringify(join(dir, "harness-sleep"))}, "utf8")); Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); } catch {}\n` +
      `let a = check ? '{"remove": []}' : '{"reviews": []}';\ntry { a = fs.readFileSync(check ? ${JSON.stringify(checkFile)} : ${JSON.stringify(answerFile)}, "utf8"); } catch {}\n` +
      `if (a === "!signedout") { console.error("Not logged in · Please run /login"); process.exit(1); }\n` +
      `console.log(JSON.stringify({ type: "result", subtype: "success", is_error: false, result: a }));\n`,
    { mode: 0o755 },
  );
  mkdirSync(join(data, "behaviors", "nightly"), { recursive: true });
  writeFileSync(join(data, "behaviors", "nightly", "config.json"), JSON.stringify({ harness: join(dir, "harness"), agent: "claude_code" }));
  extraMembers = [];
  inbox = [];
  inboxPrompt = { text: "INBOX PROMPT: file work with gh." };
  posted = [];
  nodeRecords = true;
  quiet = null;
  messages = {};
  requests = [];
  feed = [item(6), item(5, ME), item(4, OTHER, "quiet"), item(3), item(2), item(1)];
  server = createServer((req, res) => {
    const u = new URL(req.url ?? "/", "http://127.0.0.1");
    requests.push(`${u.pathname}${u.search}`);
    res.setHeader("content-type", "application/json");
    if (req.headers["x-test"] !== "yes") {
      res.statusCode = 401;
      res.end("{}");
    } else if (u.pathname === "/api/v0/feed") {
      const before = u.searchParams.get("before");
      res.end(JSON.stringify(feed.filter((i) => before === null || i.created_at < before).slice(0, PAGE)));
    } else if (u.pathname === "/api/v0/members") {
      res.end(JSON.stringify([{ identity: OTHER, name: "Ed", is_self: false }, { identity: ME, name: "Ada", is_self: true }, ...extraMembers]));
    } else if (u.pathname === "/api/v0/items") {
      res.end(JSON.stringify(inbox));
    } else if (u.pathname.startsWith("/api/v0/items/") && inbox.some((i) => i["id"] === decodeURIComponent(u.pathname.slice(14)))) {
      res.end(JSON.stringify(inbox.find((i) => i["id"] === decodeURIComponent(u.pathname.slice(14)))));
    } else if (u.pathname === "/api/v0/settings/inbox_agent" && inboxPrompt !== null) {
      res.end(JSON.stringify(inboxPrompt));
    } else if (u.pathname === "/api/v0/rules/deny") {
      res.end("[]");
    } else if (u.pathname === "/api/v0/inbox_agent/runs" && req.method === "POST") {
      let body = "";
      req.on("data", (b: Buffer) => (body += b));
      req.on("end", () => {
        const j = JSON.parse(body) as (typeof posted)[number];
        posted.push(j);
        if (!nodeRecords) {
          res.statusCode = 500;
          res.end("{}");
          return;
        }
        res.end(
          JSON.stringify({
            reviewed: j.reviews.length,
            answers: j.answers.map((a) => ({ item: a.item, outcome: a.send ? "sent" : "kept" })),
            items: j.items.map((_, n) => ({ id: `item-${n}` })),
            problems: [],
          }),
        );
      });
    } else if (u.pathname === "/api/v0/brief") {
      res.end(JSON.stringify({ text: "BRIEF: I work on compilers." }));
    } else if (u.pathname === "/api/v0/rules") {
      res.end(JSON.stringify({ text: "RULES: be brief." }));
    } else if (u.pathname === "/api/v0/learnings") {
      res.end(JSON.stringify({ text: "LEARNINGS: no emojis." }));
    } else if (u.pathname === "/api/v0/rules/quiet_hours" && quiet !== null) {
      res.end(JSON.stringify(quiet));
    } else if (u.pathname === "/api/v0/notes") {
      res.end(JSON.stringify({ notes: [{ id: "n1", preview: "LATEST first line" }] }));
    } else if (u.pathname === "/api/v0/notes/n1") {
      res.end(JSON.stringify({ version: { text: "LATEST NOTE: shipped the parser." } }));
    } else if (u.pathname.startsWith("/api/v0/messages/") && messages[decodeURIComponent(u.pathname.slice(17))] !== undefined) {
      res.end(JSON.stringify(messages[decodeURIComponent(u.pathname.slice(17))]));
    } else {
      res.statusCode = 404;
      res.end("{}");
    }
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const addr = server.address();
  url = `http://127.0.0.1:${typeof addr === "object" && addr !== null ? addr.port : 0}`;
});

afterEach(async () => {
  server.closeAllConnections();
  await new Promise((r) => server.close(r));
  rmSync(dir, { recursive: true, force: true });
});

const context = (deadlineMs = 60_000) => ({
  hook: "read",
  data_dir: data,
  digestif: join(dir, "digestif"),
  api: { url, headers: { "x-test": "yes" } },
  deadline: new Date(Date.now() + deadlineMs).toISOString(),
});
const state = () => JSON.parse(readFileSync(join(readStateDir(data), "state.json"), "utf8"));
// Asynchronous: the fake API is served by this process, which a synchronous spawn would block.
const exec = (input: string, args: string[] = []) =>
  new Promise<{ status: number | null; stdout: string; stderr: string }>((resolve) => {
    const p = spawn(process.execPath, [bin, ...args], { stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    p.stdout.on("data", (b: Buffer) => (stdout += b));
    p.stderr.on("data", (b: Buffer) => (stderr += b));
    p.once("close", (status) => resolve({ status, stdout, stderr }));
    p.stdin.end(input);
  });
const run = (c: unknown = context()) => exec(JSON.stringify(c));
const nodeCalls = (): string[] => (existsSync(nodeLog) ? readFileSync(nodeLog, "utf8").trim().split("\n") : []);
const seenHashes = (): string[] => state().seen.map((x: { hash: string }) => x.hash);
const plan = async () => {
  const lines: string[] = [];
  const status = await runRead({ ctx: parseReadContext(JSON.stringify(context())), plan: true, out: (l) => lines.push(l), log: () => {} });
  return { status, lines };
};
const setConfig = (c: unknown) => {
  mkdirSync(readStateDir(data), { recursive: true });
  writeFileSync(join(readStateDir(data), "config.json"), JSON.stringify(c));
};
const setState = (patch: Record<string, unknown>) => {
  saveState(readStateDir(data), { ...emptyState(localDay(new Date())), ...patch });
};

test("the executable pages a six-item feed two at a time, keeps others' non-status items, and moves the cursor", async () => {
  const r = await run();
  assert.equal(r.status, 0, r.stderr);
  const s = state();
  assert.equal(s.cursor, "sha256:6");
  assert.deepEqual(
    s.seen.map((x: { hash: string }) => x.hash),
    ["sha256:1", "sha256:2", "sha256:3", "sha256:6"],
  );
  assert.deepEqual(s.seen[0], { hash: "sha256:1", created_at: "2026-11-01T00:00:01Z" });
  assert.deepEqual(s.counters, { agent_runs: 1 }, "one run of the agent over the batch");
  assert.deepEqual(s.pending, [], "the node recorded the run");
  assert.match(s.day, /^\d{4}-\d{2}-\d{2}$/);
  const feeds = requests.filter((q) => q.startsWith("/api/v0/feed"));
  assert.equal(feeds.length, 4, "three pages and the empty one");
  assert.ok(feeds[0]!.includes("limit=200") && !feeds[0]!.includes("before"));
  assert.ok(feeds[1]!.includes("before=2026-11-01T00%3A00%3A05Z"));
});

test("a second run with nothing new exits 0 without running the agent", async () => {
  assert.equal((await run()).status, 0);
  requests.length = 0;
  const r = await run();
  assert.equal(r.status, 0);
  assert.match(r.stdout, /nothing new/);
  assert.deepEqual(
    requests.map((q) => q.split("?")[0]),
    ["/api/v0/feed", "/api/v0/members", "/api/v0/items"],
    "the feed, who the member is, and the Inbox items no run has reviewed",
  );
});

test("a run stops at the cursor and keeps only what came after it", async () => {
  assert.equal((await run()).status, 0);
  feed.unshift(item(8), item(7, ME));
  requests.length = 0;
  assert.equal((await run()).status, 0);
  assert.equal(state().cursor, "sha256:8");
  assert.deepEqual(
    state().seen.map((x: { hash: string }) => x.hash),
    ["sha256:1", "sha256:2", "sha256:3", "sha256:6", "sha256:8"],
  );
  assert.equal(requests.filter((q) => q.startsWith("/api/v0/feed")).length, 2, "the first page held the cursor");
});

test("an empty feed exits 0 and leaves no state", async () => {
  feed = [];
  assert.equal((await run()).status, 0);
  assert.equal(existsSync(join(readStateDir(data), "state.json")), false);
});

test("a feed it cannot read exits 1 and leaves the cursor", async () => {
  assert.equal((await run({ ...context(), api: { url, headers: { "x-test": "no" } } })).status, 1);
  assert.equal(existsSync(join(readStateDir(data), "state.json")), false);
});

test("a deadline that has passed stops the run before it reads", async () => {
  const r = await run(context(-1000));
  assert.equal(r.status, 1);
  assert.match(r.stdout, /deadline passed/);
  assert.equal(requests.length, 0);
});

test("a context for another hook, or without an api, is refused with 2", async () => {
  assert.equal((await run({ ...context(), hook: "nightly" })).status, 2);
  assert.equal((await run({ ...context(), api: null })).status, 2);
  assert.equal((await exec("nope")).status, 2);
});

test("a non-loopback api is refused with 2, as the executable and as the library", async () => {
  const bad = { ...context(), api: { url: "http://example.com", headers: {} } };
  const r = await run(bad);
  assert.equal(r.status, 2);
  assert.match(r.stdout, /loopback/);
  const lines: string[] = [];
  assert.equal(await runRead({ ctx: parseReadContext(JSON.stringify(bad)), log: (l) => lines.push(l) }), 2);
});

test("a state file that is not an object is a logged failure, exit 1, not a crash", async () => {
  mkdirSync(readStateDir(data), { recursive: true });
  writeFileSync(join(readStateDir(data), "state.json"), "null");
  const r = await run();
  assert.equal(r.status, 1);
  assert.match(r.stdout, /failed:/);
  assert.equal(r.stderr, "");
});

test("a sleep during the run moves the deadline later by as long, so the run is not cut short", async () => {
  const ctx = parseReadContext(JSON.stringify(context(5_000)));
  // The wall clock jumps an hour once the first request is in, as if the machine slept after it.
  const wall = () => Date.now() + (requests.length >= 1 ? 3_600_000 : 0);
  assert.equal(await runRead({ ctx, wall, log: () => {} }), 0);
  assert.equal(state().cursor, "sha256:6");
});

test("state: a missing file is the empty state, the counters reset with the day, the write is whole", () => {
  const d = join(dir, "state");
  assert.deepEqual(loadState(d, "2026-11-04"), emptyState("2026-11-04"));
  const pending = [{ hash: "sha256:9", type: "item" as const, created_at: "t", reads: 1 }];
  saveState(d, { ...emptyState("2026-11-03"), cursor: "sha256:1", counters: { a: 2 }, pending, seen: [{ hash: "sha256:1", created_at: "t" }] });
  assert.deepEqual(loadState(d, "2026-11-03").counters, { a: 2 });
  const next = loadState(d, "2026-11-04");
  assert.deepEqual(next.counters, {});
  assert.deepEqual(next.pending, pending, "a failed batch is read again whatever the day");
  assert.equal(next.cursor, "sha256:1");
  assert.equal(next.seen.length, 1);
  assert.deepEqual(JSON.parse(readFileSync(join(d, "state.json"), "utf8")).seen, [{ hash: "sha256:1", created_at: "t" }]);
});

test("a muted member's message is dropped if it is present, and a message is decided once", async () => {
  extraMembers = [{ identity: "ed25519:loud", is_self: false, muted: true }];
  feed = [item(2, "ed25519:loud"), item(1)];
  assert.deepEqual((await plan()).lines, ["sha256:1 keep kept", "sha256:2 drop muted"]);
  const logged: string[] = [];
  assert.equal(await runRead({ ctx: parseReadContext(JSON.stringify(context())), log: (l) => logged.push(l) }), 0);
  assert.ok(logged.some((l) => l.includes("muted member") && l.includes("sha256:2")), "a muted item in the feed is logged");
  assert.deepEqual(seenHashes(), ["sha256:1", "sha256:2"]);
  assert.deepEqual(state().recent.map((r: { author: string }) => r.author), [OTHER]);
});

test("a seen message is not decided again", async () => {
  setState({ seen: [{ hash: "sha256:3", created_at: "2026-11-01T00:00:03Z" }] });
  feed = [item(3), item(2)];
  assert.deepEqual((await plan()).lines, ["sha256:2 keep kept", "sha256:3 drop seen"]);
});

test("a chain of three messages with no person is dropped; a person, a 404 or a short chain lets it through", async () => {
  feed = [item(5), item(4), item(3), item(2), item(1)];
  messages = {
    "sha256:5": { voice: "agent", reply_to: "sha256:a1" },
    "sha256:a1": { voice: "agent", reply_to: "sha256:a2" },
    "sha256:a2": { voice: "agent" }, // three messages, none a person's
    "sha256:4": { voice: "agent", reply_to: "sha256:b1" },
    "sha256:b1": { voice: "person", reply_to: "sha256:b2" }, // a person in the chain
    "sha256:3": { voice: "agent", reply_to: "sha256:gone" }, // the parent is a 404: a chain of one
    "sha256:2": { voice: "agent", reply_to: "sha256:c1" },
    "sha256:c1": { voice: "agent" }, // two messages
  };
  const { lines } = await plan();
  assert.deepEqual(lines, ["sha256:1 keep kept", "sha256:2 keep kept", "sha256:3 keep kept", "sha256:4 keep kept", "sha256:5 drop chain_depth"]);
  assert.ok(requests.includes("/api/v0/messages/sha256%3Aa2"), "the walk went up to the third message");
});

test("a person's own voice on the item itself lets it through without a walk", async () => {
  feed = [{ ...item(1), voice: "person" } as Item];
  messages = { "sha256:1": { voice: "person", reply_to: "sha256:a" } };
  assert.deepEqual((await plan()).lines, ["sha256:1 keep kept"]);
  assert.deepEqual(requests.filter((q) => q.startsWith("/api/v0/messages")), ["/api/v0/messages/sha256%3A1"], "its own message, no walk up");
});

test("near-identical notes: same author, same text after whitespace folding, within 24 hours", async () => {
  // Every preview is the same first line: the feed does not carry the text, so the dedupe must not use it.
  const at = (n: number, h: number, who: string, text: string): Item & { preview: string } => {
    messages[`sha256:${n}`] = { voice: "agent", text };
    return {
      ...item(n, who),
      created_at: new Date(Date.parse("2026-11-01T00:00:00Z") + h * 3_600_000).toISOString(),
      preview: "Weekly update",
    };
  };
  // The feed is newest first by created_at, as the node serves it; items are decided oldest first.
  feed = [
    at(5, 30, OTHER, "Weekly update\nShipped  the fix"), // 29 hours after the first copy: outside the window
    at(6, 26, OTHER, "Weekly update\nshipped the fix"), // case differs: folding is whitespace only
    at(4, 23, OTHER, "Weekly update\n  Shipped the\nfix "), // whitespace folds: a copy
    at(3, 2, "ed25519:third", "Weekly update\nShipped the fix"), // another author
    at(2, 1, OTHER, "Weekly update\nShipped the fix"),
    at(1, 0, OTHER, "Weekly update\nDifferent body"),
  ];
  const { lines } = await plan();
  assert.deepEqual(lines, [
    "sha256:1 keep kept",
    "sha256:2 keep kept", // same first line as 1, different text
    "sha256:3 keep kept",
    "sha256:4 drop duplicate",
    "sha256:6 keep kept",
    "sha256:5 keep kept",
  ]);
});

test("over budget: the item is dropped, reported once a day, and resolved when a day starts under budget", async () => {
  setConfig({ max_agent_runs: 0 });
  const ctx = () => parseReadContext(JSON.stringify(context()));
  assert.equal(await runRead({ ctx: ctx(), log: () => {} }), 0);
  assert.deepEqual(seenHashes(), ["sha256:1", "sha256:2", "sha256:3", "sha256:6"], "decided, and kept out of the model's input");
  assert.deepEqual(state().recent, []);
  assert.deepEqual(nodeCalls(), ["problem report --job read_circle --kind out_of_budget"]);
  feed.unshift(item(7));
  assert.equal(await runRead({ ctx: ctx(), log: () => {} }), 0);
  assert.equal(nodeCalls().length, 1, "once for the day");
  assert.equal(state().out_of_budget.open, true);
  // A new day under budget: the counters reset, so the problem closes.
  setConfig({});
  const s = state();
  saveState(readStateDir(data), { ...s, day: "2000-01-01" });
  feed.unshift(item(8));
  assert.equal(await runRead({ ctx: ctx(), log: () => {} }), 0);
  assert.deepEqual(nodeCalls(), ["problem report --job read_circle --kind out_of_budget", "problem resolve --job read_circle"]);
  assert.equal(state().out_of_budget.open, false);
  assert.deepEqual(seenHashes().slice(-1), ["sha256:8"]);
  assert.equal(nodeCalls().length, 2);
});

test("an outbound counter at its limit is over budget too, and an open problem closes on a quiet feed", async () => {
  setState({ counters: { outbound: 10 }, cursor: "sha256:6" });
  feed = [item(7), ...feed];
  assert.deepEqual((await plan()).lines, ["sha256:7 drop over_budget"]);
  setState({ counters: { outbound: 9 }, cursor: "sha256:6", out_of_budget: { open: true, reported_day: "2000-01-01" } });
  feed = [item(6)];
  assert.equal(await runRead({ ctx: parseReadContext(JSON.stringify(context())), log: () => {} }), 0);
  assert.deepEqual(nodeCalls(), ["problem resolve --job read_circle"]);
});

test("config.json: a missing file or key takes the default", () => {
  const d = join(dir, "cfg");
  assert.deepEqual(loadConfig(d), { max_outbound: 10, max_agent_runs: 30 });
  mkdirSync(d, { recursive: true });
  writeFileSync(join(d, "config.json"), JSON.stringify({ max_outbound: 3, max_agent_runs: "many" }));
  assert.deepEqual(loadConfig(d), { max_outbound: 3, max_agent_runs: 30 });
});

test("--plan prints a line per fresh item, and writes no state, cursor or problem record", async () => {
  setConfig({ max_agent_runs: 0 });
  const r = await exec(JSON.stringify(context()), ["--plan"]);
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(r.stdout.trim().split("\n"), [
    "sha256:1 drop over_budget",
    "sha256:2 drop over_budget",
    "sha256:3 drop over_budget",
    "sha256:4 drop status_note",
    "sha256:5 drop own",
    "sha256:6 drop over_budget",
  ]);
  assert.equal(existsSync(join(readStateDir(data), "state.json")), false);
  assert.deepEqual(nodeCalls(), []);
});

test("any other argument is refused with 2", async () => {
  assert.equal((await exec(JSON.stringify(context()), ["--run"])).status, 2);
  assert.equal((await exec(JSON.stringify(context()), ["--plan", "x"])).status, 2);
});

test("SIGTERM ends the child the behavior started, and the behavior", async () => {
  const p = spawn(process.execPath, [join(here, "read-child.ts")], { stdio: ["ignore", "pipe", "inherit"] });
  const exited = new Promise<number | null>((r) => p.once("exit", (code) => r(code)));
  const pid = await new Promise<number>((r) => p.stdout.once("data", (b: Buffer) => r(Number(String(b).trim()))));
  assert.ok(pid > 0);
  p.kill("SIGTERM");
  assert.equal(await exited, 143);
  await assertGone(pid, "the fake harness");
});

// The Inbox agent's run: the fake harness answers what `answer` holds, the fake node records what it is posted.
const setAnswer = (a: unknown) => writeFileSync(answerFile, typeof a === "string" ? a : JSON.stringify(a));
const harnessRuns = (): { args: string[]; check: boolean; cwd: string; stdin: string }[] =>
  existsSync(harnessLog) ? readFileSync(harnessLog, "utf8").trim().split("\n").map((l) => JSON.parse(l)) : [];
const inboxRuns = () => harnessRuns().filter((r) => !r.check);
const promptOf = (r: { args: string[]; stdin: string }) => r.args.join("\n") + "\n" + r.stdin;
const go = async () => runRead({ ctx: parseReadContext(JSON.stringify(context())), log: () => {} });
/** An item that reached the member, as GET /items and GET /items/:id serve it. */
const inboxItem = (n: number, extra: Record<string, unknown> = {}) => ({
  id: `sha256:i${n}`,
  hash: `sha256:i${n}`,
  kind: "question",
  voice: "agent",
  author: { identity: OTHER, name: "Ed" },
  status: "new",
  title: `ITEM ${n} TITLE`,
  detail: `ITEM ${n} DETAIL`,
  created_at: `2026-11-01T00:01:${String(n).padStart(2, "0")}Z`,
  ...extra,
});
/** The batch the run was shown, by ref. */
const batchOf = (r: { stdin: string }) => {
  const lines = r.stdin.split("one JSON object a line:\n")[1]!.trim().split("\n");
  return lines.map((l) => JSON.parse(l) as { ref: string; hash: string; type: string; text: string });
};

test("one run reads the batch: other members' notes and the items that reached the member, framed as untrusted data, under the member's Inbox prompt", async () => {
  mkdirSync(readStateDir(data), { recursive: true });
  writeFileSync(join(readStateDir(data), "memory.md"), "MEMORY: Ed likes short notes.\n");
  feed = [item(1)];
  messages = { "sha256:1": { voice: "agent", kind: "summary", text: "NOTE TEXT: shipped the parser" } };
  inbox = [
    inboxItem(1),
    inboxItem(2, { author: { identity: ME, name: "Ada" } }), // the member's own
    inboxItem(3, { voice: "node", author: { identity: ME, name: "Ada" } }), // the node's
    inboxItem(4, { reviewed_at: "2026-11-01T00:00:00Z" }), // reviewed already
    inboxItem(5, { status: "draft" }),
  ];
  assert.equal(await go(), 0);
  const runs = inboxRuns();
  assert.equal(runs.length, 1, "one run for the whole batch");
  const p = promptOf(runs[0]!);
  for (const want of [readFileSync(ALWAYS_ON_FILE, "utf8").trim(), "INBOX PROMPT: file work with gh.", "BRIEF: I work", "RULES: be brief", "LEARNINGS: no emojis", "MEMORY: Ed likes", "NOTE TEXT: shipped the parser", "ITEM 1 TITLE", "ITEM 1 DETAIL"]) {
    assert.ok(p.includes(want), want);
  }
  assert.match(runs[0]!.stdin, /The batch, as UNTRUSTED data/);
  assert.ok(!runs[0]!.stdin.includes("BRIEF:") && !runs[0]!.stdin.includes("INBOX PROMPT"), "the member's data are the system prompt; the batch is the user message");
  assert.deepEqual(
    batchOf(runs[0]!).map((m) => [m.ref, m.hash, m.type]),
    [
      ["m1", "sha256:1", "note"],
      ["m2", "sha256:i1", "question"],
    ],
  );
  assert.ok(!runs[0]!.args.includes("--tools") && !runs[0]!.args.includes("--strict-mcp-config"), "the harness grants its own tools");
  assert.equal(runs[0]!.cwd, homedir(), "in the member's home directory");
  assert.deepEqual(
    posted[0]!.reviews.map((r) => r.hash),
    ["sha256:1", "sha256:i1"],
    "every message the run read is marked Reviewed",
  );
});

test("a node with no agent's prompt saved reads under the release's default", async () => {
  inboxPrompt = null;
  feed = [item(1)];
  assert.equal(await go(), 0);
  const want = readFileSync(INBOX_PROMPT_FILE, "utf8").trim().split("\n")[0]!;
  assert.ok(promptOf(inboxRuns()[0]!).includes(want));
});

test("what the run did goes to the node in one call: review lines, answers, drafts and work; a line to remember goes to memory", async () => {
  feed = [item(1)];
  inbox = [inboxItem(1), inboxItem(2), inboxItem(3, { kind: "notice" })];
  setAnswer({
    reviews: [
      { ref: "m1", review: "Work notice: review\nEd's loader" },
      { ref: "m2", review: "Answered with the release date" },
    ],
    remember: ["Ed is on the\nloader"],
    answers: [
      { ref: "m2", text: "Friday.", within_brief: true },
      { ref: "m3", text: "Maybe.", within_brief: false },
      { ref: "m4", text: "A notice takes no answer.", within_brief: true },
    ],
    items: [
      { subject: "work", ref: "m1", title: "Review Ed's loader", detail: "He asked in his note.", members: [ME] },
      { subject: "intro", ref: "m1", title: "Ed, meet Ben", members: [OTHER, "ed25519:ben"] },
    ],
  });
  assert.equal(await go(), 0);
  const body = posted[0]!;
  assert.deepEqual(body.reviews, [
    { hash: "sha256:1", review: "Work notice: review Ed's loader" },
    { hash: "sha256:i1", review: "Answered with the release date" },
    { hash: "sha256:i2", review: "" },
    { hash: "sha256:i3", review: "" },
  ]);
  assert.deepEqual(body.answers, [
    { item: "sha256:i1", text: "Friday.", send: true },
    { item: "sha256:i2", text: "Maybe.", send: false },
  ]);
  assert.deepEqual(
    body.items.map((i) => [i["subject"], i["about"], i["members"]]),
    [
      ["work", "sha256:1", []],
      ["intro", "sha256:1", [OTHER, "ed25519:ben"]],
    ],
  );
  assert.equal(readFileSync(join(readStateDir(data), "memory.md"), "utf8"), "Ed is on the loader\n");
  assert.equal(state().counters.outbound, 3, "an answer sent and two items written");
  assert.equal(harnessRuns().filter((r) => r.check).length, 2, "both checks read the answer the agent would send");
});

test("an answer either check would cut is kept for the member, never sent", async () => {
  inbox = [inboxItem(1)];
  feed = [];
  setAnswer({ reviews: [{ ref: "m1", review: "Answered" }], answers: [{ ref: "m1", text: "It ships Friday to Acme.", within_brief: true }] });
  writeFileSync(checkFile, JSON.stringify({ remove: [{ text: "It ships Friday to Acme.", breaks: "rules" }] }));
  assert.equal(await go(), 0);
  assert.equal(posted[0]!.answers[0]!.send, false);
});

test("a failed run leaves its batch unreviewed and reads it again with the next sync's, at most three times", async () => {
  feed = [item(1)];
  setAnswer("not json");
  assert.equal(await go(), 0);
  assert.equal(posted.length, 0, "nothing is recorded");
  assert.deepEqual(state().pending, [{ hash: "sha256:1", type: "note", created_at: "2026-11-01T00:00:01Z", reads: 1 }]);
  assert.deepEqual(nodeCalls(), ["problem report --job read_circle --kind model_unavailable"]);
  // The next sync carries a new item and reads the note again with it.
  inbox = [inboxItem(1)];
  messages = { "sha256:1": { voice: "agent", text: "NOTE AGAIN" } };
  assert.equal(await go(), 0);
  assert.deepEqual(
    batchOf(inboxRuns()[1]!).map((m) => m.hash),
    ["sha256:1", "sha256:i1"],
  );
  assert.deepEqual(
    state().pending.map((p: { hash: string; reads: number }) => [p.hash, p.reads]),
    [
      ["sha256:1", 2],
      ["sha256:i1", 1],
    ],
  );
  // A node that does not record the run fails it the same way.
  setAnswer({ reviews: [] });
  nodeRecords = false;
  assert.equal(await go(), 0);
  assert.deepEqual(
    state().pending.map((p: { hash: string; reads: number }) => [p.hash, p.reads]),
    [["sha256:i1", 2]],
    "read three times, the note is left unreviewed",
  );
  nodeRecords = true;
  assert.equal(await go(), 0);
  assert.deepEqual(state().pending, []);
  assert.deepEqual(posted.at(-1)!.reviews.map((r) => r.hash), ["sha256:i1"]);
});

test("the run's answer is checked: refs the batch does not hold, unknown subjects and malformed lists are a run that could not finish", () => {
  const refs = new Set(["m1"]);
  assert.ok("error" in parseRun("nope", refs));
  assert.ok("error" in parseRun('{"reviews": [{"ref": "m9"}]}', refs));
  assert.ok("error" in parseRun('{"items": [{"subject": "meeting", "ref": "m1", "title": "Coffee"}]}', refs));
  assert.ok("error" in parseRun('{"items": [{"subject": "intro", "ref": "m1", "title": ""}]}', refs));
  assert.ok("error" in parseRun('{"answers": [{"ref": "m1", "text": " "}]}', refs));
  assert.ok("error" in parseRun('{"reviews": "all"}', refs));
  const ok = parseRun('```json\n{"reviews": [{"ref": "m1", "review": "Nothing"}]}\n```', refs);
  assert.ok(!("error" in ok) && ok.reviews.get("m1") === "Nothing", "one pair of code fences is read through");
});

test("a run is only made while the day's agent runs are under the limit", async () => {
  setConfig({ max_agent_runs: 1 });
  feed = [item(2), item(1)];
  assert.equal(await go(), 0);
  feed.unshift(item(3));
  assert.equal(await go(), 0);
  assert.equal(inboxRuns().length, 1);
  assert.deepEqual(nodeCalls(), ["problem report --job read_circle --kind out_of_budget"]);
});

test("a run problem reported in a run is not closed by that run's out_of_budget resolve", async () => {
  setState({ out_of_budget: { open: true, reported_day: "2000-01-01" } });
  setAnswer("not json");
  feed = [item(1)];
  assert.equal(await go(), 0);
  assert.deepEqual(nodeCalls(), ["problem report --job read_circle --kind model_unavailable"]);
});

test("--plan runs no agent", async () => {
  feed = [item(1)];
  await plan();
  assert.equal(harnessRuns().length, 0);
});

test("the prompt builder refuses a template without the always-on text and includes the file's text", () => {
  assert.throws(() => buildReadPrompt("Read the feed."), /always_on_rules/);
  const text = readFileSync(ALWAYS_ON_FILE, "utf8").trim();
  const p = buildReadPrompt("Rules:\n{{always_on_rules}}\nEnd.");
  assert.ok(p.includes(text));
  assert.ok(!p.includes("{{always_on_rules}}"));
  const own = join(dir, "always-on.md");
  mkdirSync(dir, { recursive: true });
  writeFileSync(own, "never do X\n");
  assert.equal(buildReadPrompt("{{always_on_rules}}", own), "never do X");
});
