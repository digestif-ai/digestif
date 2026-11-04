// The read behavior: run against a fake local API over fixture feeds.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";
import {
  buildReadPrompt,
  emptyState,
  flagAllowed,
  loadConfig,
  loadState,
  localDay,
  parseReadContext,
  readStateDir,
  recordFlag,
  runRead,
  saveState,
} from "../src/read.ts";
import { ALWAYS_ON_FILE } from "../src/writer.ts";
import { assertGone } from "./processes.ts";

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

let dir: string;
let data: string;
let server: Server;
let url: string;
let feed: Item[]; // newest first
let requests: string[];
let extraMembers: { identity: string; is_self: boolean; muted?: boolean }[];
let messages: Record<string, { voice: string; reply_to?: string; text?: string }>; // what GET /messages/:hash knows
let nodeLog: string; // the fake `digestif` appends its arguments here
const PAGE = 2; // the fake serves two a page whatever the limit asked

beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), "digestif-read-test-"));
  data = join(dir, "data");
  nodeLog = join(dir, "node.log");
  writeFileSync(join(dir, "digestif"), `#!/bin/sh\necho "$@" >> "${nodeLog}"\n`, { mode: 0o755 });
  extraMembers = [];
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
      res.end(JSON.stringify([{ identity: OTHER, is_self: false }, { identity: ME, is_self: true }, ...extraMembers]));
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
  assert.deepEqual(s.counters, {});
  assert.match(s.day, /^\d{4}-\d{2}-\d{2}$/);
  const feeds = requests.filter((q) => q.startsWith("/api/v0/feed"));
  assert.equal(feeds.length, 4, "three pages and the empty one");
  assert.ok(feeds[0]!.includes("limit=200") && !feeds[0]!.includes("before"));
  assert.ok(feeds[1]!.includes("before=2026-11-01T00%3A00%3A05Z"));
});

test("a second run with nothing new exits 0 at once, without asking who the member is", async () => {
  assert.equal((await run()).status, 0);
  requests.length = 0;
  const r = await run();
  assert.equal(r.status, 0);
  assert.match(r.stdout, /nothing new/);
  assert.deepEqual(requests.length, 1);
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
  saveState(d, { ...emptyState("2026-11-03"), cursor: "sha256:1", counters: { a: 2 }, flags: { x: 1 }, seen: [{ hash: "sha256:1", created_at: "t" }] });
  assert.deepEqual(loadState(d, "2026-11-03").counters, { a: 2 });
  const next = loadState(d, "2026-11-04");
  assert.deepEqual(next.counters, {});
  assert.deepEqual(next.flags, {});
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
  assert.deepEqual(loadConfig(d), { max_outbound: 10, max_flags_per_sender: 1, max_agent_runs: 30 });
  mkdirSync(d, { recursive: true });
  writeFileSync(join(d, "config.json"), JSON.stringify({ max_outbound: 3, max_agent_runs: "many" }));
  assert.deepEqual(loadConfig(d), { max_outbound: 3, max_flags_per_sender: 1, max_agent_runs: 30 });
});

test("flags: a sender at the limit gets no further flag honored, and the day resets it", () => {
  const cfg = loadConfig(join(dir, "none"));
  const s = emptyState("2026-11-04");
  assert.equal(flagAllowed(s, "ed25519:a", cfg), true);
  recordFlag(s, "ed25519:a");
  assert.equal(flagAllowed(s, "ed25519:a", cfg), false);
  assert.equal(flagAllowed(s, "ed25519:b", cfg), true);
  const d = join(dir, "flags");
  saveState(d, s);
  assert.deepEqual(loadState(d, "2026-11-04").flags, { "ed25519:a": 1 });
  assert.deepEqual(loadState(d, "2026-11-05").flags, {});
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
