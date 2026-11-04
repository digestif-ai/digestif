// The read behavior (docs/behaviors.md, the `read` hook): the node runs it when a message arrives. This
// story reads the feed up to the cursor, keeps the items a later story will act on in the seen set, and
// moves the cursor. It calls no model; the prompt builder below is what the later stories run through.

import { spawn, type ChildProcess, type SpawnOptions } from "node:child_process";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { AwakeClock } from "./awake.ts";
import { decide } from "./decision.ts";
import { harnessOf, readConfig } from "./hook.ts";
import { hookStateDir, reportProblem, resolveProblem } from "./nightly.ts";
import { ALWAYS_ON_FILE, ALWAYS_ON_PLACEHOLDER, killHarnesses, nodeApi, type ApiAccess } from "./writer.ts";

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

/** A kept item's author and folded text, for the dedupe window. */
export interface Recent {
  author: string;
  text: string;
  created_at: string;
}

/** The out_of_budget problem: reported once a local day, resolved when a day starts under budget. */
export interface BudgetProblem {
  open: boolean;
  reported_day: string | null;
}

/** `state.json`: the behavior's own state. */
export interface ReadState {
  /** The hash of the newest feed item handled; null before the first run. */
  cursor: string | null;
  /** The local date the counters are for. */
  day: string;
  /** Per-day counters: `outbound` (messages sent, notes excluded) and `agent_runs`. Reset when `day` changes. */
  counters: Record<string, number>;
  /** Per-day flags honored, keyed by sender identity. Reset when `day` changes. */
  flags: Record<string, number>;
  /** Every message decided (kept, or dropped: an over_budget drop is final too, since the cursor moves past it), so it is decided once. */
  seen: Seen[];
  /** Kept items of the last 24 hours, for the dedupe of near-identical notes. */
  recent: Recent[];
  out_of_budget: BudgetProblem;
}

/** The per-day limits; `<data_dir>/behaviors/read/config.json` may set any of them. */
export interface ReadConfig {
  max_outbound: number;
  max_flags_per_sender: number;
  max_agent_runs: number;
}

export const DEFAULT_CONFIG: ReadConfig = { max_outbound: 10, max_flags_per_sender: 1, max_agent_runs: 30 };

/** A missing file, or a missing or non-count key, takes the default. */
export function loadConfig(stateDir: string): ReadConfig {
  let j: Record<string, unknown> = {};
  try {
    const parsed: unknown = JSON.parse(readFileSync(join(stateDir, "config.json"), "utf8"));
    if (typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)) j = parsed as Record<string, unknown>;
  } catch {
    /* absent or unreadable: the defaults */
  }
  const n = (k: keyof ReadConfig): number => {
    const v = j[k];
    return typeof v === "number" && Number.isInteger(v) && v >= 0 ? v : DEFAULT_CONFIG[k];
  };
  return { max_outbound: n("max_outbound"), max_flags_per_sender: n("max_flags_per_sender"), max_agent_runs: n("max_agent_runs") };
}

/** True when a counter is at its limit: nothing that needs an agent run or a message may run. */
export function overBudget(state: ReadState, config: ReadConfig): boolean {
  return (state.counters["outbound"] ?? 0) >= config.max_outbound || (state.counters["agent_runs"] ?? 0) >= config.max_agent_runs;
}

/** Whether a flag from this sender may still be honored today. */
export function flagAllowed(state: ReadState, sender: string, config: ReadConfig): boolean {
  return (state.flags[sender] ?? 0) < config.max_flags_per_sender;
}

/** Called when a flagged propose is honored: the decision run's `propose` with `"flag": true`. */
export function recordFlag(state: ReadState, sender: string): void {
  state.flags[sender] = (state.flags[sender] ?? 0) + 1;
}

/** Counts text the way the dedupe compares it: whitespace folded to single spaces. */
export const foldText = (s: string): string => s.replace(/\s+/g, " ").trim();

export const DEDUPE_WINDOW_MS = 24 * 3_600_000;
/** A chain of this many messages with no `person` voice in it is dropped. */
export const MAX_CHAIN = 3;
/** How many earlier messages of a chain the decision run is shown. */
export const CHAIN_IN_PROMPT = 5;

export const readStateDir = (dataDir: string): string => join(dataDir, "behaviors", "read");

export function localDay(now: Date): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())}`;
}

export function emptyState(day: string): ReadState {
  return { cursor: null, day, counters: {}, flags: {}, seen: [], recent: [], out_of_budget: { open: false, reported_day: null } };
}

const isRecord = (v: unknown): v is Record<string, number> => typeof v === "object" && v !== null && !Array.isArray(v);

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
  const counters = sameDay && isRecord(j["counters"]) ? j["counters"] : {};
  const flags = sameDay && isRecord(j["flags"]) ? j["flags"] : {};
  const recent = Array.isArray(j["recent"])
    ? (j["recent"] as Recent[]).filter((r) => isStr(r?.author) && isStr(r?.text) && isStr(r?.created_at))
    : [];
  const b = j["out_of_budget"] as Partial<BudgetProblem> | null | undefined;
  const out_of_budget: BudgetProblem = { open: b?.open === true, reported_day: isStr(b?.reported_day) ? b.reported_day : null };
  return { cursor: isStr(j["cursor"]) ? j["cursor"] : null, day, counters, flags, seen, recent, out_of_budget };
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
  kind?: string;
  created_at: string;
  author: { identity: string };
  voice?: string;
  preview?: string;
  status_note?: unknown;
}

export const FEED_LIMIT = 200;

/** Why an item was dropped, or `kept`. */
export type Reason = "kept" | "status_note" | "own" | "seen" | "muted" | "duplicate" | "over_budget" | "chain_depth";

export interface ReadOptions {
  ctx: ReadContext;
  /** `--plan`: print what would run and why; call no model; write no state, cursor or problem record. */
  plan?: boolean;
  now?: Date;
  /** Where `--plan` prints its lines. */
  out?: (line: string) => void;
  /** The wall clock, in milliseconds; tests move it to stand in for a sleep. */
  wall?: () => number;
  log?: (line: string) => void;
}

/**
 * One run. Returns the exit status: 0 once what was read is recorded (or nothing was new), 1 when the
 * feed or the state file could not be read or the deadline passed first (the cursor stays, so the next
 * run reads it again), 2 when the api is not the node's loopback address.
 */
export async function runRead(options: ReadOptions): Promise<number> {
  const { ctx } = options;
  const now = options.now ?? new Date();
  const log = options.log ?? ((l: string) => console.log(`${new Date().toISOString()} ${l}`));
  const stateDir = readStateDir(ctx.dataDir);
  // The node measures the deadline in time the machine is awake: a sleep moves it later by as long.
  const clock = new AwakeClock(options.wall).start();
  const wall = options.wall ?? Date.now;

  const get = async (path: string, params: Record<string, string> = {}, allow404 = false): Promise<unknown> => {
    const left = ctx.deadline.getTime() + clock.slept() - wall();
    if (left <= 0) throw new DeadlinePassed();
    const url = new URL(`/api/v0/${path}`, base);
    for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
    const res = await fetch(url, { headers, signal: AbortSignal.timeout(Math.min(left, 30_000)) });
    if (allow404 && res.status === 404) return null;
    if (!res.ok) throw new Error(`${path}: HTTP ${res.status}`);
    return res.json();
  };
  type Msg = { voice?: string; reply_to?: string; text?: string; kind?: string };
  const message = async (hash: string): Promise<Msg | null> => {
    const m = await get(`messages/${encodeURIComponent(hash)}`, {}, true);
    return typeof m === "object" && m !== null ? m : null;
  };
  /** True when the item's reply chain has MAX_CHAIN messages or more and none is a person's; `first` is the item's own message. */
  const chainTooDeep = async (item: FeedItem, first: Msg | null): Promise<boolean> => {
    if (item.voice === "person") return false;
    let count = 1;
    let m = first;
    for (;;) {
      const parent = m?.reply_to;
      if (!isStr(parent) || parent === "") return false;
      m = await message(parent);
      if (m === null) return false;
      count++;
      if (m.voice === "person") return false;
      if (count >= MAX_CHAIN) return true;
    }
  };
  /** The texts of the messages `first` replies to, nearest first, for the decision run. */
  const chainTexts = async (first: Msg | null): Promise<string[]> => {
    const out: string[] = [];
    const visited = new Set<string>();
    let m = first;
    while (out.length < CHAIN_IN_PROMPT) {
      const parent = m?.reply_to;
      if (!isStr(parent) || parent === "" || visited.has(parent)) break;
      visited.add(parent);
      m = await message(parent);
      if (m === null) break;
      if (isStr(m.text) && m.text.trim() !== "") out.push(m.text);
    }
    return out;
  };
  /** The member's latest note, in full when the node serves its text, else its preview; empty when there is none. */
  const latestNote = async (): Promise<string> => {
    try {
      const list = (await get("notes", { limit: "1" })) as { notes?: { id?: string; preview?: string }[] } | null;
      const n = list?.notes?.[0];
      if (n === undefined) return "";
      if (isStr(n.id)) {
        const page = (await get(`notes/${encodeURIComponent(n.id)}`, {}, true)) as { version?: { text?: string } } | null;
        if (isStr(page?.version?.text)) return page.version.text;
      }
      return isStr(n.preview) ? n.preview : "";
    } catch (e) {
      if (e instanceof DeadlinePassed) throw e;
      return "";
    }
  };
  const say = (l: string): void => {
    if (!options.plan) log(l);
  };

  let base: URL;
  let headers: Record<string, string>;
  try {
    ({ base, headers } = nodeApi(ctx.api));
  } catch (e) {
    clock.stop();
    log(`refused: ${(e as Error).message}`);
    return 2;
  }
  const page = async (before: string | undefined): Promise<FeedItem[]> => {
    const body = await get("feed", { limit: String(FEED_LIMIT), ...(before === undefined ? {} : { before }) });
    if (!Array.isArray(body)) throw new Error("feed: not a list");
    return body as FeedItem[];
  };

  try {
    const state = loadState(stateDir, localDay(now));
    const config = loadConfig(stateDir);
    const over = overBudget(state, config);
    let overDrop = false;
    let decisionProblem = false;
    // A day that starts under budget closes the problem an earlier day opened, unless this run dropped something over budget
    // or reported a decision problem: resolving the job without a source would close that one too.
    const settle = async (): Promise<void> => {
      if (options.plan || over || overDrop || decisionProblem || !state.out_of_budget.open) return;
      const err = await resolveProblem(ctx.digestif, "read_circle");
      if (err !== undefined) {
        log(`could not resolve the out_of_budget problem: ${err}`);
        return;
      }
      state.out_of_budget.open = false;
      saveState(stateDir, state);
    };
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
      await settle();
      say("nothing new");
      return 0;
    }
    const members = await get("members");
    const rows = Array.isArray(members) ? (members as { identity?: string; is_self?: boolean; muted?: boolean; encryption_key?: string }[]) : [];
    const self = rows.find((m) => m.is_self === true)?.identity;
    if (self === undefined) throw new Error("members: no entry is the member's own");
    const muted = new Set(rows.filter((m) => m.muted === true).map((m) => m.identity));
    const known = new Set(state.seen.map((s) => s.hash));
    state.recent = state.recent.filter((r) => now.getTime() - Date.parse(r.created_at) < DEDUPE_WINDOW_MS);
    let kept = 0;
    // What every decision run is given besides its message, fetched once and only when a message passes.
    let given: { harness: ReturnType<typeof harnessOf>; brief: string; rules: string; learnings: string; note: string } | undefined;
    const textOf = (body: unknown): string => {
      const t = (body as { text?: unknown } | null)?.text;
      return isStr(t) ? t : "";
    };
    /** One decision run for a message that passed the filter. It is decided once: the state is saved first. */
    const decideOne = async (i: FeedItem, own: Msg | null): Promise<void> => {
      if (ctx.deadline.getTime() + clock.slept() - wall() <= 0) throw new DeadlinePassed();
      given ??= {
        harness: harnessOf(await readConfig(hookStateDir(ctx.dataDir))),
        brief: textOf(await get("brief")),
        rules: textOf(await get("rules")),
        learnings: textOf(await get("learnings", {}, true)),
        note: await latestNote(),
      };
      const chain = await chainTexts(own);
      const sender = rows.find((m) => m.identity === i.author.identity)?.encryption_key;
      const mine = rows.find((m) => m.is_self === true)?.encryption_key;
      state.counters["agent_runs"] = (state.counters["agent_runs"] ?? 0) + 1;
      saveState(stateDir, state);
      const done = await decide({
        digestif: ctx.digestif,
        stateDir,
        harness: given.harness,
        brief: given.brief,
        rules: given.rules,
        learnings: given.learnings,
        latestNote: given.note,
        message: { hash: i.hash, kind: own?.kind ?? i.kind ?? "", text: isStr(own?.text) ? own.text : (i.preview ?? ""), author: i.author.identity, chain },
        keys: {
          ...(sender === undefined ? {} : { sender }),
          ...(mine === undefined ? {} : { self: mine }),
        },
        log,
        now,
        flags: {
          allowed: () => flagAllowed(state, i.author.identity, config),
          record: () => {
            recordFlag(state, i.author.identity);
            saveState(stateDir, state);
          },
        },
        quietHours: async () => {
          try {
            const q = (await get("rules/quiet_hours", {}, true)) as { active?: unknown; ends_at?: unknown } | null;
            if (q === null || typeof q !== "object") return null;
            return { active: q.active === true, ...(isStr(q.ends_at) ? { ends_at: q.ends_at } : {}) };
          } catch (e) {
            if (e instanceof DeadlinePassed) throw e;
            log(`could not read the quiet hours: ${(e as Error).message}`);
            return null;
          }
        },
        onProblem: () => {
          decisionProblem = true;
        },
      });
      if (done.outbound > 0) state.counters["outbound"] = (state.counters["outbound"] ?? 0) + done.outbound;
      if ((done.flagOverBudget ?? 0) > 0) state.counters["flags_over_budget"] = (state.counters["flags_over_budget"] ?? 0) + done.flagOverBudget!;
      if (done.outbound > 0 || (done.flagOverBudget ?? 0) > 0) saveState(stateDir, state);
    };
    // Oldest first, so of two near-identical notes the earlier is the one kept.
    for (const i of [...fresh].reverse()) {
      let reason: Reason = "kept";
      let text = "";
      let own: Msg | null = null;
      const at = Date.parse(i.created_at);
      if (i.status_note !== undefined && i.status_note !== null) reason = "status_note";
      else if (i.author.identity === self) reason = "own";
      else if (known.has(i.hash)) reason = "seen";
      else if (muted.has(i.author.identity)) {
        reason = "muted";
        // The node filters muted members before any agent run; seeing one here means it no longer does.
        say(`a muted member's item ${i.hash} is in the feed; the node should have filtered it`);
      } else {
        // The feed's preview is only the first line; the dedupe compares the message's full text, fetched once.
        own = await message(i.hash);
        text = foldText(isStr(own?.text) ? own.text : "");
      }
      if (reason !== "kept") {
        /* decided above */
      } else if (text !== "" && state.recent.some((r) => r.author === i.author.identity && r.text === text && Math.abs(at - Date.parse(r.created_at)) < DEDUPE_WINDOW_MS)) {
        reason = "duplicate";
      } else if (overBudget(state, config)) reason = "over_budget";
      else if (await chainTooDeep(i, own)) reason = "chain_depth";
      if (options.plan) {
        (options.out ?? console.log)(`${i.hash} ${reason === "kept" ? "keep" : "drop"} ${reason}`);
        if (reason === "kept") state.recent.push({ author: i.author.identity, text, created_at: i.created_at });
        continue;
      }
      if (reason === "status_note" || reason === "own" || reason === "seen") continue;
      known.add(i.hash);
      state.seen.push({ hash: i.hash, created_at: i.created_at });
      if (reason === "over_budget") overDrop = true;
      if (reason === "kept") {
        state.recent.push({ author: i.author.identity, text, created_at: i.created_at });
        kept++;
        await decideOne(i, own);
      }
    }
    if (options.plan) return 0;
    if (overDrop && state.out_of_budget.reported_day !== state.day) {
      const err = await reportProblem(ctx.digestif, "read_circle", "out_of_budget");
      if (err === undefined) state.out_of_budget = { open: true, reported_day: state.day };
      else log(`could not report the out_of_budget problem: ${err}`);
    }
    state.cursor = newest ?? state.cursor;
    saveState(stateDir, state);
    await settle();
    log(`read ${fresh.length} new items, kept ${kept}`);
    return 0;
  } catch (e) {
    if (e instanceof DeadlinePassed) {
      log("the deadline passed before the feed was read; the cursor stays");
    } else {
      log(`failed: ${(e as Error).message}`);
    }
    return 1;
  } finally {
    clock.stop();
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
    killHarnesses();
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
