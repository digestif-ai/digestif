// The read behavior: run against a fake local API over fixture feeds.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";
import { buildReadPrompt, emptyState, loadState, parseReadContext, readStateDir, runRead, saveState } from "../src/read.ts";
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
const PAGE = 2; // the fake serves two a page whatever the limit asked

beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), "digestif-read-test-"));
  data = join(dir, "data");
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
      res.end(JSON.stringify([{ identity: OTHER, is_self: false }, { identity: ME, is_self: true }]));
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
  digestif: "digestif",
  api: { url, headers: { "x-test": "yes" } },
  deadline: new Date(Date.now() + deadlineMs).toISOString(),
});
const state = () => JSON.parse(readFileSync(join(readStateDir(data), "state.json"), "utf8"));
// Asynchronous: the fake API is served by this process, which a synchronous spawn would block.
const exec = (input: string) =>
  new Promise<{ status: number | null; stdout: string; stderr: string }>((resolve) => {
    const p = spawn(process.execPath, [bin], { stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    p.stdout.on("data", (b: Buffer) => (stdout += b));
    p.stderr.on("data", (b: Buffer) => (stderr += b));
    p.once("close", (status) => resolve({ status, stdout, stderr }));
    p.stdin.end(input);
  });
const run = (c: unknown = context()) => exec(JSON.stringify(c));

test("the executable pages a six-item feed two at a time, keeps others' non-status items, and moves the cursor", async () => {
  const r = await run();
  assert.equal(r.status, 0, r.stderr);
  const s = state();
  assert.equal(s.cursor, "sha256:6");
  assert.deepEqual(
    s.seen.map((x: { hash: string }) => x.hash),
    ["sha256:6", "sha256:3", "sha256:2", "sha256:1"],
  );
  assert.deepEqual(s.seen[0], { hash: "sha256:6", created_at: "2026-11-01T00:00:06Z" });
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
    ["sha256:6", "sha256:3", "sha256:2", "sha256:1", "sha256:8"],
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
  assert.deepEqual(loadState(d, "2026-11-04"), { cursor: null, day: "2026-11-04", counters: {}, seen: [] });
  saveState(d, { ...emptyState("2026-11-03"), cursor: "sha256:1", counters: { a: 2 }, seen: [{ hash: "sha256:1", created_at: "t" }] });
  assert.deepEqual(loadState(d, "2026-11-03").counters, { a: 2 });
  const next = loadState(d, "2026-11-04");
  assert.deepEqual(next.counters, {});
  assert.equal(next.cursor, "sha256:1");
  assert.equal(next.seen.length, 1);
  assert.deepEqual(JSON.parse(readFileSync(join(d, "state.json"), "utf8")).seen, [{ hash: "sha256:1", created_at: "t" }]);
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
