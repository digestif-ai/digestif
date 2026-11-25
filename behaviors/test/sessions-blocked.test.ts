// A folder whose reading blocks for good (DIG-483): judging gives up on it at the limit, the rest of
// the source is read, and the process that reads ends by itself.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Folders, FolderTimedOut } from "../src/folders.ts";
import { MAX_LISTING_MS } from "../src/sessions.ts";
import { blocked, type Blocked } from "./blocked.ts";
import { assertGone } from "./processes.ts";

interface Judged {
  files: string[];
  skipped: [string, string][];
  unreadable: [string, string][];
}

/** One reading in a process of its own, killed after `withinMs`. */
async function judge(root: string, home: string, b: Blocked, withinMs: number): Promise<Judged> {
  const child = spawn(process.execPath, [join(import.meta.dirname, "judge-child.ts"), join(root, "projects"), root, home], { env: { ...process.env, ...b.env }, stdio: ["ignore", "pipe", "inherit"] });
  const late = setTimeout(() => child.kill("SIGKILL"), withinMs);
  let out = "";
  child.stdout.setEncoding("utf8").on("data", (d: string) => (out += d));
  const [code, signal] = await new Promise<[number | null, string | null]>((r) => child.on("close", (c, s) => r([c, s])));
  clearTimeout(late);
  assert.deepEqual([code, signal], [0, null], `the reading ends by itself within ${withinMs} ms`);
  return JSON.parse(out) as Judged;
}

/** A root with a home and a projects directory holding one transcript in each named project. */
function layout(names: string[]): { root: string; transcript: (name: string) => string } {
  const root = mkdtempSync(join(tmpdir(), "digestif-blocked-"));
  const transcript = (name: string): string => join(root, "projects", name, "s.jsonl");
  for (const name of names) {
    mkdirSync(join(root, "projects", name), { recursive: true });
    writeFileSync(transcript(name), JSON.stringify({ type: "user", message: { role: "user", content: "A prompt" }, timestamp: new Date().toISOString() }) + "\n");
  }
  return { root, transcript };
}

test("a listing that blocks before its first entry gives up as too slow, and the next project is judged (DIG-483)", async () => {
  const { root, transcript } = layout(["-home-cloud-a", "-home-cloud-b", "-home-code-app"]);
  const cloud = join(root, "home", "cloud");
  for (const d of ["a", "b"]) mkdirSync(join(cloud, d), { recursive: true });
  mkdirSync(join(root, "home", "code", "app"), { recursive: true });
  const b = blocked(root, cloud);
  try {
    const r = await judge(root, join(root, "home"), b, 4 * MAX_LISTING_MS);
    assert.deepEqual(r.files, [transcript("-home-code-app")], "the project beside it is read");
    assert.deepEqual(r.skipped.map(([, why]) => why), ["slow", "slow"], "both projects in it are skipped as too slow");
    assert.deepEqual(r.unreadable, [[cloud, "too slow to list"]], "told of once");
    assert.equal(b.pids().length, 1, "and it cost one limit, though two projects reached it");
    await assertGone(b.pids()[0]!, "the process that was reading it");
  } finally {
    b.release();
    rmSync(root, { recursive: true, force: true });
  }
});

test("a project at home lists no child of home unless its name reads as finance (DIG-483)", async () => {
  const { root, transcript } = layout(["-home"]);
  mkdirSync(join(root, "home", "cloud"), { recursive: true });
  mkdirSync(join(root, "home", "finance"), { recursive: true });
  const unlisted = blocked(root, join(root, "home", "cloud"));
  try {
    const r = await judge(root, join(root, "home"), unlisted, 4 * MAX_LISTING_MS);
    assert.deepEqual(r.files, [transcript("-home")]);
    assert.deepEqual(unlisted.pids(), [], "a child not named for finance is never opened");
  } finally {
    unlisted.release();
    rmSync(join(root, "block.fifo"));
  }
  const listed = blocked(root, join(root, "home", "finance"));
  try {
    const r = await judge(root, join(root, "home"), listed, 4 * MAX_LISTING_MS);
    assert.deepEqual(r.skipped.map(([, why]) => why), ["slow"], "one named for finance is, so a block there skips the project");
  } finally {
    listed.release();
    rmSync(root, { recursive: true, force: true });
  }
});

test("a folder call past its limit is a timeout, and the next call is made by another process (DIG-483)", async () => {
  const root = mkdtempSync(join(tmpdir(), "digestif-folders-"));
  const b = blocked(root, join(root, "cloud"));
  const old = { ...process.env };
  Object.assign(process.env, b.env);
  const folders = new Folders();
  try {
    await assert.rejects(folders.list(join(root, "cloud"), 10, 300), (e: unknown) => e instanceof FolderTimedOut && !e.started);
    assert.deepEqual((await folders.list(root, 10, 10_000)).names.sort(), ["block.fifo", "block.log"]);
    assert.deepEqual(await folders.list(root, 1, 10_000).then((l) => [l.names.length, l.over]), [1, true], "cut at max");
    assert.equal(await folders.isDirectory(root, 10_000), true);
    assert.equal(await folders.isDirectory(b.fifo, 10_000), false);
    await assert.rejects(folders.isDirectory(join(root, "absent"), 10_000), { code: "ENOENT" });
    await assert.rejects(folders.list(b.fifo, 10, 10_000), { code: "ENOTDIR" });
    await assertGone(b.pids()[0]!, "the process that timed out");
  } finally {
    folders.close();
    for (const k of Object.keys(b.env)) if (old[k] === undefined) delete process.env[k];
      else process.env[k] = old[k];
    b.release();
    rmSync(root, { recursive: true, force: true });
  }
});
