// The folders judging looks at, read where a call that blocks can be abandoned (DIG-483). A listing or
// a stat can block in the kernel for as long as the system likes (macOS asking whether this process may
// read a folder while nobody is at the screen), and a promise over one cannot be given up: its thread
// stays blocked, and Node.js waits for that thread to exit. So each call is made by a child process
// (src/folder-reader.ts), killed with SIGKILL at the call's limit and never waited for; the next call
// starts another.

import { spawn, type ChildProcess } from "node:child_process";
import { join } from "node:path";
import type { Answer, Request } from "./folder-reader.ts";

/** A call took longer than its limit: the child making it was killed. */
export class FolderTimedOut extends Error {
  /** The folder answered with its first entry, so the listing is long rather than blocked. */
  readonly started: boolean;
  constructor(path: string, ms: number, started: boolean) {
    super(`${path} did not answer in ${ms} ms`);
    this.started = started;
  }
}

/** The child's answer to a call that failed, with the error's code as Node.js gives it. */
class FolderError extends Error {
  readonly code: string;
  constructor(path: string, code: string) {
    super(`${path}: ${code}`);
    this.code = code;
  }
}

type Reply = Exclude<Answer, { ready: true } | { started: true }>;

/** What the call being made, or the start of the child, is told. */
interface Waiting {
  ready?: () => void;
  started?: () => void;
  answered?: (r: Reply) => void;
  failed: (why: string) => void;
}

/** How long the child may take to start: a busy machine's time, not a folder's, so no call's limit counts it. */
const START_LIMIT_MS = 10_000;

/** The longest timer Node.js keeps; a longer one fires at once. */
const MAX_TIMER_MS = 2 ** 31 - 1;

const live = new Set<ChildProcess>();

/** Kills every child reading folders now. Synchronous: it is called from a signal handler that ends the process right after. */
export function killFolderReaders(): void {
  for (const c of live) c.kill("SIGKILL");
  live.clear();
}

/** Keeps no process alive by itself: a pending call's timer does, and only until its limit. */
const unref = (h: unknown): void => (h as { unref?: () => void } | null)?.unref?.();

/** One reading's folder calls, made one at a time by one child. Close it when the reading is over. */
export class Folders {
  #child: ChildProcess | undefined;
  #waiting: Waiting | undefined;
  #last: Promise<unknown> = Promise.resolve();

  /** A folder's entries, at most `max` of them; `over` says there are more. */
  async list(path: string, max: number, limitMs: number): Promise<{ names: string[]; over: boolean }> {
    return (await this.#call({ op: "list", path, max }, limitMs)) as { names: string[]; over: boolean };
  }

  async isDirectory(path: string, limitMs: number): Promise<boolean> {
    return ((await this.#call({ op: "stat", path }, limitMs)) as { dir: boolean }).dir;
  }

  close(): void {
    this.#abandon();
  }

  #call(r: Request, limitMs: number): Promise<Reply> {
    const made = this.#last.then(() => this.#make(r, limitMs));
    this.#last = made.catch(() => undefined);
    return made;
  }

  async #make(r: Request, limitMs: number): Promise<Reply> {
    const child = this.#child ?? (await this.#start(r.path));
    let started = false;
    return this.#within<Reply>(r.path, limitMs, () => new FolderTimedOut(r.path, limitMs, started), (resolve, reject) => {
      child.stdin?.write(JSON.stringify(r) + "\n");
      return {
        started: () => void (started = true),
        answered: (a) => ("error" in a ? reject(new FolderError(r.path, a.error)) : resolve(a)),
      };
    });
  }

  /** Waits on the child for at most `limitMs`, then gives the child up. */
  #within<T>(path: string, limitMs: number, late: () => Error, ask: (resolve: (v: T) => void, reject: (e: Error) => void) => Omit<Waiting, "failed">): Promise<T> {
    let timer: NodeJS.Timeout | undefined;
    return new Promise<T>((resolve, reject) => {
      timer = setTimeout(() => {
        this.#abandon();
        reject(late());
      }, Math.min(limitMs, MAX_TIMER_MS));
      this.#waiting = { failed: (why) => reject(new FolderError(path, why)), ...ask(resolve, reject) };
    }).finally(() => {
      clearTimeout(timer);
      this.#waiting = undefined;
    });
  }

  async #start(path: string): Promise<ChildProcess> {
    const child = spawn(process.execPath, [join(import.meta.dirname, "folder-reader.ts")], { stdio: ["pipe", "pipe", "ignore"] });
    live.add(child);
    this.#child = child;
    for (const h of [child, child.stdin, child.stdout]) unref(h);
    const failed = (why: string): void => {
      live.delete(child);
      if (this.#child !== child) return;
      this.#child = undefined;
      this.#waiting?.failed(why);
    };
    child.on("error", (e) => failed(e.message));
    child.on("exit", () => failed("the process reading folders ended"));
    child.stdin.on("error", () => undefined); // A child that is gone: its exit says so.
    let part: string[] = [];
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      const lines = chunk.split("\n");
      for (const [i, text] of lines.entries()) {
        part.push(text);
        if (i === lines.length - 1) break;
        const a = JSON.parse(part.join("")) as Answer;
        part = [];
        if (this.#child !== child || this.#waiting === undefined) continue;
        if ("ready" in a) this.#waiting.ready?.();
        else if ("started" in a) this.#waiting.started?.();
        else this.#waiting.answered?.(a);
      }
    });
    const late = (): Error => new FolderError(path, "the process reading folders did not start");
    await this.#within<void>(path, START_LIMIT_MS, late, (resolve) => ({ ready: resolve }));
    return child;
  }

  /** Kills the child and lets go of it, whether or not the kill is obeyed yet. */
  #abandon(): void {
    const child = this.#child;
    if (child === undefined) return;
    this.#child = undefined;
    live.delete(child);
    child.kill("SIGKILL");
    child.stdin?.destroy();
    child.stdout?.destroy();
  }
}
