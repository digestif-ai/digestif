// The read behavior: run against a fake local API over fixture feeds.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createDecipheriv, createPublicKey, diffieHellman, generateKeyPairSync, hkdfSync, type KeyObject } from "node:crypto";
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
import { canonical, seal, type Sealed } from "../src/seal.ts";
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
let messages: Record<string, { voice: string; reply_to?: string; text?: string; kind?: string }>; // what GET /messages/:hash knows
let quiet: { start: string; end: string; active: boolean; ends_at?: string } | null; // GET /rules/quiet_hours; null is a 404
let nodeLog: string; // the fake `digestif` appends its arguments here
let answerFile: string; // what the fake harness answers, one line; "!signedout" makes it a login failure
let harnessLog: string; // the fake harness appends one JSON line per run: its arguments and stdin
const PAGE = 2; // the fake serves two a page whatever the limit asked
const keyPair = () => {
  const { publicKey, privateKey } = generateKeyPairSync("x25519");
  return { privateKey, key: "x25519:" + publicKey.export({ format: "der", type: "spki" }).subarray(-32).toString("base64url") };
};
let meKeys: ReturnType<typeof keyPair>;
let otherKeys: ReturnType<typeof keyPair>;

beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), "digestif-read-test-"));
  data = join(dir, "data");
  nodeLog = join(dir, "node.log");
  answerFile = join(dir, "answer");
  harnessLog = join(dir, "harness.log");
  meKeys = keyPair();
  otherKeys = keyPair();
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
      `fs.appendFileSync(${JSON.stringify(harnessLog)}, JSON.stringify({ args: process.argv.slice(2), stdin: fs.readFileSync(0, "utf8") }) + "\\n");\n` +
      `try { const ms = Number(fs.readFileSync(${JSON.stringify(join(dir, "harness-sleep"))}, "utf8")); Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); } catch {}\n` +
      `let a = '{"outcome":"nothing"}';\ntry { a = fs.readFileSync(${JSON.stringify(answerFile)}, "utf8"); } catch {}\n` +
      `if (a === "!signedout") { console.error("Not logged in · Please run /login"); process.exit(1); }\n` +
      `console.log(JSON.stringify({ type: "result", subtype: "success", is_error: false, result: a }));\n`,
    { mode: 0o755 },
  );
  mkdirSync(join(data, "behaviors", "nightly"), { recursive: true });
  writeFileSync(join(data, "behaviors", "nightly", "config.json"), JSON.stringify({ harness: join(dir, "harness"), agent: "claude_code" }));
  extraMembers = [];
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
      res.end(JSON.stringify([{ identity: OTHER, is_self: false, encryption_key: otherKeys.key }, { identity: ME, is_self: true, encryption_key: meKeys.key }, ...extraMembers]));
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
  assert.deepEqual(s.counters, { agent_runs: 4 }, "one run of the agent for each kept message");
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

// The decision run: the fake harness answers what `answer` holds, the fake digestif records what it is handed.

const setAnswer = (a: string) => writeFileSync(answerFile, a);
const harnessRuns = (): { args: string[]; stdin: string }[] =>
  existsSync(harnessLog) ? readFileSync(harnessLog, "utf8").trim().split("\n").map((l) => JSON.parse(l)) : [];
const promptOf = (r: { args: string[]; stdin: string }) => r.args.join("\n") + "\n" + r.stdin;
const go = async () => runRead({ ctx: parseReadContext(JSON.stringify(context())), log: () => {} });
/** Opens a sealed value for `priv`, following docs/protocol.md, Sealing, independently of src/seal.ts. */
const open = (sealed: Sealed, priv: KeyObject, key: string): unknown => {
  const mine = Buffer.from(key.slice(7), "base64url");
  const entry = sealed.recipients.find((r: { key: string }) => r.key === key);
  assert.ok(entry, "sealed to this key");
  const eph = Buffer.from(entry.ephemeral.slice(7), "base64url");
  const theirs = createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b656e032100", "hex"), eph]), format: "der", type: "spki" });
  const w = Buffer.from(hkdfSync("sha256", diffieHellman({ privateKey: priv, publicKey: theirs }), Buffer.concat([eph, mine]), "digestif-v0 seal", 32));
  const gcm = (k: Buffer, n: Buffer, data: Buffer, adata?: string) => {
    const d = createDecipheriv("aes-256-gcm", k, n);
    if (adata !== undefined) d.setAAD(Buffer.from(adata));
    d.setAuthTag(data.subarray(-16));
    return Buffer.concat([d.update(data.subarray(0, -16)), d.final()]);
  };
  const k = gcm(w, Buffer.alloc(12), Buffer.from(entry.wrapped, "base64url"));
  const plain = gcm(k, Buffer.from(sealed.nonce, "base64url"), Buffer.from(sealed.ciphertext, "base64url"), "digestif-v0 sealed");
  return JSON.parse(plain.toString());
};

test("the decision prompt carries the always-on rules, brief, Rules, Learnings, memory, the latest note, the message and its chain, and says the message is untrusted", async () => {
  mkdirSync(readStateDir(data), { recursive: true });
  writeFileSync(join(readStateDir(data), "memory.md"), "MEMORY: Ed likes short notes.\n");
  feed = [item(1)];
  messages = {
    "sha256:1": { voice: "agent", kind: "summary", text: "NEW MESSAGE: call me", reply_to: "sha256:p1" },
    "sha256:p1": { voice: "agent", text: "EARLIER MESSAGE: hello" },
  };
  assert.equal(await go(), 0);
  const runs = harnessRuns();
  assert.equal(runs.length, 1);
  const p = promptOf(runs[0]!);
  for (const want of [readFileSync(ALWAYS_ON_FILE, "utf8").trim(), "BRIEF: I work", "RULES: be brief", "LEARNINGS: no emojis", "MEMORY: Ed likes", "LATEST NOTE: shipped the parser", "NEW MESSAGE: call me", "EARLIER MESSAGE: hello"]) {
    assert.ok(p.includes(want), want);
  }
  assert.match(p, /UNTRUSTED INPUT/);
  assert.ok(runs[0]!.args.includes("--tools") && runs[0]!.args[runs[0]!.args.indexOf("--tools") + 1] === "", "no tools");
  assert.ok(!runs[0]!.stdin.includes("BRIEF:"), "the message and the member's data are the user message; the instructions are the system prompt");
});

test("nothing: the run counts, and nothing is posted, noted or asked", async () => {
  setAnswer('{"outcome":"nothing"}');
  feed = [item(1)];
  assert.equal(await go(), 0);
  assert.equal(state().counters.agent_runs, 1);
  assert.deepEqual(nodeCalls(), []);
  assert.equal(existsSync(join(readStateDir(data), "memory.md")), false);
});

test("note: one line is appended to memory.md, and the next run is shown it", async () => {
  setAnswer('{"outcome":"note","text":"Ed asked about compilers"}');
  feed = [item(2), item(1)];
  assert.equal(await go(), 0);
  assert.equal(readFileSync(join(readStateDir(data), "memory.md"), "utf8"), "Ed asked about compilers\nEd asked about compilers\n");
  const runs = harnessRuns();
  assert.ok(!promptOf(runs[0]!).includes("Ed asked about compilers"));
  assert.ok(promptOf(runs[1]!).includes("Ed asked about compilers"));
  assert.deepEqual(nodeCalls(), []);
});

test("reply: sealed to the sender's and the member's own card keys, posted as an answer to a question and a question otherwise, counted as outbound", async () => {
  setAnswer('{"outcome":"reply","text":"Thursday works"}');
  feed = [item(2), item(1)];
  messages = { "sha256:2": { voice: "agent", kind: "question", text: "Free Thursday?" }, "sha256:1": { voice: "agent", kind: "summary", text: "FYI" } };
  assert.equal(await go(), 0);
  assert.deepEqual(nodeCalls(), ["post --kind question --body -", "post --kind answer --body -"]);
  const body = JSON.parse(readFileSync(join(dir, "stdin-post"), "utf8"));
  assert.equal(body.to, OTHER);
  assert.equal(body.reply_to, "sha256:2");
  assert.equal(body.sealed.alg, "x25519-hkdf-sha256-a256gcm");
  assert.deepEqual(body.sealed.recipients.map((r: { key: string }) => r.key), [otherKeys.key, meKeys.key]);
  assert.deepEqual(open(body.sealed, otherKeys.privateKey, otherKeys.key), { text: "Thursday works", voice: "agent" });
  assert.deepEqual(open(body.sealed, meKeys.privateKey, meKeys.key), { text: "Thursday works", voice: "agent" });
  assert.equal(state().counters.outbound, 2);
  assert.equal(state().counters.agent_runs, 2);
});

test("reply refused by the deny layer (exit 3): the rule is reported, never the text, and nothing is retried", async () => {
  writeFileSync(join(dir, "post-exit3"), "");
  setAnswer('{"outcome":"reply","text":"SECRET-REPLY-TEXT"}');
  feed = [item(1)];
  assert.equal(await go(), 0);
  assert.deepEqual(nodeCalls(), ["post --kind question --body -", "problem report --job read_circle --kind failed --source no customer names"]);
  assert.ok(!nodeCalls().join("\n").includes("SECRET-REPLY-TEXT"));
  assert.equal(state().counters.outbound ?? 0, 0);
  assert.deepEqual(seenHashes(), ["sha256:1"]);
  assert.equal(await go(), 0);
  assert.equal(harnessRuns().length, 1, "the message is decided once");
});

test("reply with no card key to seal to is a problem, and posts nothing", async () => {
  otherKeys.key = "";
  setAnswer('{"outcome":"reply","text":"hi"}');
  feed = [item(1)];
  assert.equal(await go(), 0);
  assert.deepEqual(nodeCalls(), ["problem report --job read_circle --kind failed"]);
});

test("propose: digestif ask add gets the ask on stdin, keyed by the message, with the agent's deadline as lapses_at", async () => {
  const ask = {
    outcome: "propose",
    kind: "intro",
    title: "Introduce Phong to Andrey?",
    detail: "Phong asked about eval harnesses.",
    options: [
      { id: "yes", label: "Yes, introduce them", recommended: true },
      { id: "no", label: "No" },
    ],
    on_no_answer: "no",
    deadline_at: "2026-11-06T09:00:00.000Z",
  };
  setAnswer(JSON.stringify(ask));
  feed = [item(1)];
  assert.equal(await go(), 0);
  assert.deepEqual(nodeCalls(), ["ask add - --key read-sha256:1"]);
  assert.deepEqual(JSON.parse(readFileSync(join(dir, "stdin-ask"), "utf8")), {
    kind: "intro",
    title: ask.title,
    detail: ask.detail,
    options: ask.options,
    on_no_answer: "no",
    lapses_at: "2026-11-06T09:00:00.000Z",
    about: "sha256:1",
  });
  assert.equal(state().counters.outbound ?? 0, 0);
});

const proposal = (extra: Record<string, unknown> = {}) =>
  JSON.stringify({
    outcome: "propose",
    kind: "share",
    title: "t",
    detail: "d",
    options: [{ id: "a", label: "A", recommended: true }],
    on_no_answer: "a",
    ...extra,
  });
const askLapses = (): string | undefined => JSON.parse(readFileSync(join(dir, "stdin-ask"), "utf8")).lapses_at;
const hoursFromNow = (h: number) => new Date(Date.now() + h * 3_600_000).toISOString();

test("a flag within the budget raises one ask and is counted; a second from the same sender the same day raises none, writes the over-budget note and counts it", async () => {
  setAnswer(proposal({ flag: true }));
  feed = [item(2), item(1)];
  assert.equal(await go(), 0);
  assert.deepEqual(nodeCalls(), ["ask add - --key read-sha256:1"], "the first is honored, the second is not");
  assert.deepEqual(state().flags, { [OTHER]: 1 });
  assert.equal(state().counters.flags_over_budget, 1);
  const memory = readFileSync(join(readStateDir(data), "memory.md"), "utf8");
  assert.equal(memory, `The flag on message sha256:2 from ${OTHER} was over budget; no ask was raised.\n`);
});

test("a propose with no flag is not held to the flag budget", async () => {
  setAnswer(proposal());
  feed = [item(2), item(1)];
  assert.equal(await go(), 0);
  assert.equal(nodeCalls().length, 2);
  assert.deepEqual(state().flags, {});
  assert.equal(state().counters.flags_over_budget, undefined);
});

test("quiet hours: 404 leaves lapses_at as written, inactive leaves it, active moves a later-than-day deadline past ends_at and gives a missing one the same", async () => {
  const written = hoursFromNow(30);
  feed = [item(1)];
  setAnswer(proposal({ deadline_at: written }));
  assert.equal(await go(), 0);
  assert.equal(askLapses(), written, "no quiet hours set");

  rmSync(join(readStateDir(data), "state.json"));
  quiet = { start: "22:00", end: "07:00", active: false };
  assert.equal(await go(), 0);
  assert.equal(askLapses(), written, "inactive");

  const ends = hoursFromNow(30);
  const after = new Date(Date.parse(ends) + 24 * 3_600_000).toISOString();
  quiet = { start: "22:00", end: "07:00", active: true, ends_at: ends };
  rmSync(join(readStateDir(data), "state.json"));
  setAnswer(proposal({ deadline_at: hoursFromNow(26) }));
  assert.equal(await go(), 0);
  assert.equal(askLapses(), after, "a deadline a day or more away but before ends_at moves to ends_at plus a day");
});

test("quiet hours: an ask with a deadline inside a day keeps it; one with no deadline gets ends_at plus a day; one already past ends_at is unchanged", async () => {
  const ends = hoursFromNow(6);
  quiet = { start: "22:00", end: "07:00", active: true, ends_at: ends };
  feed = [item(1)];
  const soon = hoursFromNow(3);
  setAnswer(proposal({ deadline_at: soon }));
  assert.equal(await go(), 0);
  assert.equal(askLapses(), soon);

  rmSync(join(readStateDir(data), "state.json"));
  setAnswer(proposal());
  assert.equal(await go(), 0);
  assert.equal(askLapses(), new Date(Date.parse(ends) + 24 * 3_600_000).toISOString());

  rmSync(join(readStateDir(data), "state.json"));
  const later = hoursFromNow(40);
  setAnswer(proposal({ deadline_at: later }));
  assert.equal(await go(), 0);
  assert.equal(askLapses(), later);
});

test("a flag is counted only once its ask is raised: a failed `ask add` leaves the sender's budget for a later message the same day", async () => {
  writeFileSync(join(dir, "ask-fail-once"), "");
  setAnswer(proposal({ flag: true }));
  feed = [item(2), item(1)];
  assert.equal(await go(), 0);
  assert.deepEqual(nodeCalls(), ["ask add - --key read-sha256:1", "problem report --job read_circle --kind failed", "ask add - --key read-sha256:2"]);
  assert.deepEqual(state().flags, { [OTHER]: 1 }, "only the ask that was raised is counted");
  assert.equal(state().counters.flags_over_budget, undefined);
});

test("a deadline that passes during the harness run does not lose the ask: the quiet hours are not read, and the ask is raised as written", async () => {
  writeFileSync(join(dir, "harness-sleep"), "6000"); // well past the deadline below, which is wide enough that a loaded machine reaches the harness first
  quiet = { start: "22:00", end: "07:00", active: true, ends_at: hoursFromNow(6) };
  setAnswer(proposal({ flag: true }));
  feed = [item(1)];
  assert.equal(await runRead({ ctx: parseReadContext(JSON.stringify(context(5000))), log: () => {} }), 0);
  assert.deepEqual(nodeCalls(), ["ask add - --key read-sha256:1"]);
  assert.equal(askLapses(), undefined, "as the agent wrote it");
  assert.deepEqual(state().flags, { [OTHER]: 1 });
});

test("an answer that is not one line of JSON with a known outcome, or no answer at all, is a reported problem and the message is not run again", async () => {
  const good = { outcome: "propose", kind: "share", title: "t", detail: "d", options: [{ id: "a", label: "A", recommended: true }], on_no_answer: "a" };
  const bad: [string, string][] = [
    ["not json", "model_unavailable"],
    ['{"outcome":"nothing"}\n{"outcome":"nothing"}', "model_unavailable"],
    ['{"outcome":"shrug"}', "model_unavailable"],
    ['{"outcome":"reply"}', "model_unavailable"],
    [JSON.stringify({ ...good, kind: "gossip" }), "model_unavailable"],
    [JSON.stringify({ ...good, options: [{ id: "a", label: "A" }] }), "model_unavailable"],
    [JSON.stringify({ ...good, options: [{ id: "a", label: "A", recommended: true }, { id: "b", label: "B", recommended: true }] }), "model_unavailable"],
    [JSON.stringify({ ...good, on_no_answer: undefined }), "model_unavailable"],
    [JSON.stringify({ ...good, on_no_answer: "zzz" }), "model_unavailable"],
    [JSON.stringify({ ...good, deadline_at: "soon" }), "model_unavailable"],
    ["", "model_unavailable"],
    ["!signedout", "signed_out"],
  ];
  for (const [answer, kind] of bad) {
    rmSync(nodeLog, { force: true });
    rmSync(join(readStateDir(data), "state.json"), { force: true });
    rmSync(harnessLog, { force: true });
    setAnswer(answer);
    feed = [item(1)];
    assert.equal(await go(), 0, answer);
    assert.deepEqual(nodeCalls(), [`problem report --job read_circle --kind ${kind}`], answer);
    assert.equal(state().counters.agent_runs, 1, answer);
    assert.deepEqual(seenHashes(), ["sha256:1"], answer);
    assert.equal(existsSync(join(readStateDir(data), "memory.md")), false, answer);
    assert.equal(await go(), 0);
    assert.equal(harnessRuns().length, 1, `${answer}: not run again`);
  }
});

test("a run is only made while the day's agent runs are under the limit", async () => {
  setConfig({ max_agent_runs: 1 });
  feed = [item(2), item(1)];
  assert.equal(await go(), 0);
  assert.equal(harnessRuns().length, 1);
  assert.deepEqual(nodeCalls(), ["problem report --job read_circle --kind out_of_budget"]);
});

test("a decision problem reported in a run is not closed by that run's out_of_budget resolve", async () => {
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

test("sealing: the value opens for every recipient, and a key of the wrong shape is refused", () => {
  const a = keyPair();
  const sealed = seal({ voice: "agent", text: "héllo \"q\"" }, [a.key]);
  assert.deepEqual(open(sealed, a.privateKey, a.key), { text: 'héllo "q"', voice: "agent" });
  assert.throws(() => seal({}, ["ed25519:abc"]), /x25519/);
  assert.throws(() => seal({}, ["x25519:AAAA"]), /32 bytes/);
  assert.equal(canonical({ b: [1, "x"], a: { d: true, c: null } }), '{"a":{"c":null,"d":true},"b":[1,"x"]}');
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
