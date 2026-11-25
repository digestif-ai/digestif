// A folder whose reading blocks (block-folder.mjs), for the tests that spawn what reads it.
import { execFileSync } from "node:child_process";
import { closeSync, constants, existsSync, openSync, readFileSync } from "node:fs";
import { join } from "node:path";

const preload = join(import.meta.dirname, "block-folder.mjs");

export interface Blocked {
  fifo: string;
  /** The environment a program blocks on `folder` in, and what it starts. */
  env: Record<string, string>;
  /** The pid of each process that blocked, one for each time it did. */
  pids: () => number[];
  /** Lets go of whatever still waits on the FIFO. */
  release: () => void;
}

/** Blocks reading `folder`, with its FIFO and log kept in `dir`. */
export function blocked(dir: string, folder: string): Blocked {
  const fifo = join(dir, "block.fifo");
  const log = join(dir, "block.log");
  execFileSync("mkfifo", [fifo]);
  return {
    fifo,
    env: { BLOCK_FOLDER: folder, BLOCK_FIFO: fifo, BLOCK_LOG: log, NODE_OPTIONS: `--import=${preload}` },
    pids: () => (existsSync(log) ? readFileSync(log, "utf8").trim().split("\n").map(Number) : []),
    release: () => closeSync(openSync(fifo, constants.O_RDWR | constants.O_NONBLOCK)),
  };
}
