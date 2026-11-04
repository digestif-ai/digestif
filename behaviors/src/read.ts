// The read behavior (docs/behaviors.md, the `read` hook): the node runs it when a message arrives. This
// story reads the feed up to the cursor, keeps the items a later story will act on in the seen set, and
// moves the cursor. It calls no model; the prompt builder below is what the later stories run through.

import { spawn, type ChildProcess, type SpawnOptions } from "node:child_process";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { ALWAYS_ON_FILE, ALWAYS_ON_PLACEHOLDER, nodeApi, type ApiAccess } from "./writer.ts";

/** The context the node hands the read hook on stdin, checked. */
export interface ReadContext {
  dataDir: string;
  digestif: string;
  api: ApiAccess;
  deadline: Date;
}

/** Thrown for a context this behavior refuses; the exit status is 2. */
export class ReadContextError extends Error {}

const isStr = (v: unknown): v is string => typeof v === "string";

export function parseReadContext(text: string): ReadContext {
  let j: unknown;
  try {
    j = JSON.parse(text);
  } catch {
    throw new ReadContextError("stdin is not a JSON object");
  }
  if (typeof j !== "object" || j === null || Array.isArray(j)) throw new ReadContextError("stdin is not a JSON object");
  const o = j as Record<string, unknown>;
  if (o["hook"] !== "read") throw new ReadContextError(`hook ${JSON.stringify(o["hook"])} is not "read"`);
  if (!isStr(o["data_dir"]) || o["data_dir"] === "") throw new ReadContextError("data_dir must be a path");
  if (!isStr(o["digestif"]) || o["digestif"] === "") throw new ReadContextError("digestif must be a path");
  const a = o["api"] as Record<string, unknown> | null | undefined;
  const h = a?.["headers"];
  if (typeof a !== "object" || a === null || !isStr(a["url"]) || typeof h !== "object" || h === null || !Object.values(h).every(isStr)) {
    throw new ReadContextError("api must be { url, headers }");
  }
  const deadline = new Date(isStr(o["deadline"]) ? o["deadline"] : NaN);
  if (Number.isNaN(deadline.getTime())) throw new ReadContextError("deadline must be a time");
  return { dataDir: o["data_dir"], digestif: o["digestif"], api: { url: a["url"], headers: h as Record<string, string> }, deadline };
}

/** One item kept for the later stories. */
export interface Seen {
  hash: string;
  created_at: string;
}

/** `state.json`: the behavior's own state. */
export interface ReadState {
  /** The hash of the newest feed item handled; null before the first run. */
  cursor: string | null;
  /** The local date the counters are for. */
  day: string;
  /** Per-day counters; no budget exists yet, so it is empty. Reset when `day` changes. */
  counters: Record<string, number>;
  seen: Seen[];
}

export const readStateDir = (dataDir: string): string => join(dataDir, "behaviors", "read");

export function localDay(now: Date): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())}`;
}

export function emptyState(day: string): ReadState {
  return { cursor: null, day, counters: {}, seen: [] };
}

/** A missing file is the empty state; the counters of an earlier day are dropped. */
export function loadState(stateDir: string, day: string): ReadState {
  let raw: string;
  try {
    raw = readFileSync(join(stateDir, "state.json"), "utf8");
  } catch {
    return emptyState(day);
  }
  let j: Record<string, unknown>;
  try {
    j = JSON.parse(raw) as Record<string, unknown>;
  } catch {
    throw new Error(`${join(stateDir, "state.json")} is not JSON`);
  }
  const seen = Array.isArray(j["seen"]) ? (j["seen"] as Seen[]).filter((s) => isStr(s?.hash) && isStr(s?.created_at)) : [];
  const sameDay = j["day"] === day;
  const counters = sameDay && typeof j["counters"] === "object" && j["counters"] !== null ? (j["counters"] as Record<string, number>) : {};
  return { cursor: isStr(j["cursor"]) ? j["cursor"] : null, day, counters, seen };
}

/** Writes the whole file through a temp file and a rename. */
export function saveState(stateDir: string, state: ReadState): void {
  mkdirSync(stateDir, { recursive: true });
  const file = join(stateDir, "state.json");
  const tmp = `${file}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(state, null, 2) + "\n");
  renameSync(tmp, file);
}

/** A feed item, as far as this behavior reads it. */
interface FeedItem {
  hash: string;
  created_at: string;
  author: { identity: string };
  status_note?: unknown;
}

export const FEED_LIMIT = 200;

export interface ReadOptions {
  ctx: ReadContext;
  now?: Date;
  log?: (line: string) => void;
}

/**
 * One run. Returns the exit status: 0 once what was read is recorded (or nothing was new), 1 when the
 * feed could not be read or the deadline passed first (the cursor stays, so the next run reads it again).
 */
export async function runRead(options: ReadOptions): Promise<number> {
  const { ctx } = options;
  const now = options.now ?? new Date();
  const log = options.log ?? ((l: string) => console.log(`${new Date().toISOString()} ${l}`));
  const stateDir = readStateDir(ctx.dataDir);
  const state = loadState(stateDir, localDay(now));
  const { base, headers } = nodeApi(ctx.api);

  const get = async (path: string, params: Record<string, string> = {}): Promise<unknown> => {
    const left = ctx.deadline.getTime() - Date.now();
    if (left <= 0) throw new DeadlinePassed();
    const url = new URL(`/api/v0/${path}`, base);
    for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
    const res = await fetch(url, { headers, signal: AbortSignal.timeout(Math.min(left, 30_000)) });
    if (!res.ok) throw new Error(`${path}: HTTP ${res.status}`);
    return res.json();
  };
  const page = async (before: string | undefined): Promise<FeedItem[]> => {
    const body = await get("feed", { limit: String(FEED_LIMIT), ...(before === undefined ? {} : { before }) });
    if (!Array.isArray(body)) throw new Error("feed: not a list");
    return body as FeedItem[];
  };

  try {
    const fresh: FeedItem[] = [];
    let newest: string | undefined;
    let before: string | undefined;
    for (;;) {
      const items = await page(before);
      if (items.length === 0) break;
      newest ??= items[0]!.hash;
      const at = items.findIndex((i) => i.hash === state.cursor);
      fresh.push(...(at < 0 ? items : items.slice(0, at)));
      if (at >= 0) break;
      const oldest = items[items.length - 1]!.created_at;
      if (oldest === before) break;
      before = oldest;
    }
    if (fresh.length === 0) {
      log("nothing new");
      return 0;
    }
    const members = await get("members");
    const self = Array.isArray(members) ? (members as { identity?: string; is_self?: boolean }[]).find((m) => m.is_self === true)?.identity : undefined;
    if (self === undefined) throw new Error("members: no entry is the member's own");
    const known = new Set(state.seen.map((s) => s.hash));
    let kept = 0;
    for (const i of fresh) {
      if (i.status_note !== undefined && i.status_note !== null) continue;
      if (i.author.identity === self || known.has(i.hash)) continue;
      known.add(i.hash);
      state.seen.push({ hash: i.hash, created_at: i.created_at });
      kept++;
    }
    state.cursor = newest ?? state.cursor;
    saveState(stateDir, state);
    log(`read ${fresh.length} new items, kept ${kept}`);
    return 0;
  } catch (e) {
    if (e instanceof DeadlinePassed) {
      log("the deadline passed before the feed was read; the cursor stays");
    } else {
      log(`failed: ${(e as Error).message}`);
    }
    return 1;
  }
}

class DeadlinePassed extends Error {}

/** Child processes this run started (a harness, in the later stories), so a SIGTERM can end them. */
const children = new Set<ChildProcess>();

/** Starts a child in its own process group and tracks it until it exits. */
export function startChild(command: string, args: string[], options: SpawnOptions = {}): ChildProcess {
  const child = spawn(command, args, { ...options, detached: true });
  children.add(child);
  child.once("exit", () => children.delete(child));
  return child;
}

/** Kills every tracked child's whole process group. Synchronous: it runs in a signal handler. */
export function killChildren(): number {
  let n = 0;
  for (const c of children) {
    try {
      if (c.pid !== undefined) process.kill(-c.pid, "SIGKILL");
      n++;
    } catch {
      /* already gone */
    }
  }
  children.clear();
  return n;
}

/** The node's deadline is a SIGTERM: end the children, then the process. */
export function endOnSigterm(): void {
  process.once("SIGTERM", () => {
    killChildren();
    process.exit(143);
  });
}

/**
 * The system prompt for a later story's model call: the template with the always-on rules, read from
 * prompts/always-on.md (ALWAYS_ON_FILE) and not copied here. A template without the placeholder is
 * refused rather than run without the rules.
 */
export function buildReadPrompt(template: string, alwaysOnFile: string = ALWAYS_ON_FILE): string {
  if (!template.includes(ALWAYS_ON_PLACEHOLDER)) {
    throw new Error(`the prompt does not include ${ALWAYS_ON_PLACEHOLDER}; every prompt that acts for a member does`);
  }
  const rules = readFileSync(alwaysOnFile, "utf8").trim();
  return template.split(ALWAYS_ON_PLACEHOLDER).join(rules);
}
