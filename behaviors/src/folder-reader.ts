// The child process judging reads folders in (src/folders.ts): one JSON request a line on stdin, one
// JSON answer a line on stdout. Every call is synchronous on the one thread, so a folder that blocks
// blocks this process and nothing else, and SIGKILL ends it. It ends by itself when stdin does.
import { opendirSync, statSync } from "node:fs";
import { createInterface } from "node:readline";

export type Request = { op: "list"; path: string; max: number } | { op: "stat"; path: string };

/** `ready` is said once, before any request: the process has started. `started` says a listing's first entry was read, or that it has none: what is left is size, not a block. */
export type Answer = { ready: true } | { started: true } | { names: string[]; over: boolean } | { found: boolean; dir: boolean } | { error: string };

const say = (a: Answer): void => void process.stdout.write(JSON.stringify(a) + "\n");

function list(path: string, max: number): Answer {
  const names: string[] = [];
  const d = opendirSync(path);
  try {
    let e = d.readSync();
    say({ started: true });
    for (; e !== null; e = d.readSync()) {
      if (names.length >= max) return { names, over: true };
      names.push(e.name);
    }
    return { names, over: false };
  } finally {
    d.closeSync();
  }
}

function answer(r: Request): Answer {
  try {
    if (r.op === "list") return list(r.path, r.max);
    return { found: true, dir: statSync(r.path).isDirectory() };
  } catch (e) {
    const code = (e as NodeJS.ErrnoException).code;
    return { error: code ?? (e as Error).message };
  }
}

// The reader that asked is gone: nothing is left to answer.
process.stdout.on("error", () => process.exit(0));
say({ ready: true });
for await (const line of createInterface({ input: process.stdin })) say(answer(JSON.parse(line) as Request));
