// The read behavior (docs/behaviors.md, the `read` hook): the node runs it when a message arrives.
// Code reads the feed up to the cursor and the Inbox items no run has reviewed, drops what was
// already seen, what a muted member sent and what is over budget, and hands the rest to one run of
// the member's Inbox agent (src/inbox.ts, docs/design.md, The Inbox agent). A run that fails leaves
// its batch unreviewed, and those messages are read again with the next sync's, at most MAX_READS
// times in all.

import { spawn, type ChildProcess, type SpawnOptions } from "node:child_process";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { AwakeClock } from "./awake.ts";
import { readDenyList } from "./deny.ts";
import { harnessOf, readConfig } from "./hook.ts";
import { INBOX_PROMPT_FILE, MAX_READS, runInbox, type BatchMessage, type Member, type OwnNote } from "./inbox.ts";
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

/** A message handed to a run: a note or an item, decided once. */
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

/** A message whose run failed: it is read again with the next batch, until it has been read MAX_READS times. */
export interface Pending {
  hash: string;
  type: "note" | "item";
  created_at: string;
  reads: number;
}

/** `state.json`: the behavior's own state. */
export interface ReadState {
  /** The hash of the newest feed item handled; null before the first run. */
  cursor: string | null;
  /** The local date the counters are for. */
  day: string;
  /** Per-day counters: `outbound` (answers and work notices sent) and `agent_runs`. Reset when `day` changes. */
  counters: Record<string, number>;
  /** The messages of failed runs, read again with the next batch. */
  pending: Pending[];
  /** Every message decided (kept, or dropped: an over_budget drop is final too, since the cursor moves past it), so it is decided once. */
  seen: Seen[];
  /** Kept items of the last 24 hours, for the dedupe of near-identical notes. */
  recent: Recent[];
  out_of_budget: BudgetProblem;
}

/** The per-day limits; `<data_dir>/behaviors/read/config.json` may set any of them. */
export interface ReadConfig {
  max_outbound: number;
  max_agent_runs: number;
}

export const DEFAULT_CONFIG: ReadConfig = { max_outbound: 10, max_agent_runs: 30 };

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
  return { max_outbound: n("max_outbound"), max_agent_runs: n("max_agent_runs") };
}

/** True when a counter is at its limit: nothing that needs an agent run or a message may run. */
export function overBudget(state: ReadState, config: ReadConfig): boolean {
  return (state.counters["outbound"] ?? 0) >= config.max_outbound || (state.counters["agent_runs"] ?? 0) >= config.max_agent_runs;
}

/** Counts text the way the dedupe compares it: whitespace folded to single spaces. */
export const foldText = (s: string): string => s.replace(/\s+/g, " ").trim();

export const DEDUPE_WINDOW_MS = 24 * 3_600_000;
/** A chain of this many messages with no `person` voice in it is dropped. */
export const MAX_CHAIN = 3;
/** How many Inbox items one sync reads: a page of GET /items. */
export const ITEMS_LIMIT = 200;

/** How many of the member's own shared notes a run is handed, and how far back. */
export const OWN_NOTES = 3;
export const OWN_NOTES_WINDOW_MS = 14 * 86_400_000;

export const readStateDir = (dataDir: string): string => join(dataDir, "behaviors", "read");

export function localDay(now: Date): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())}`;
}

export function emptyState(day: string): ReadState {
  return { cursor: null, day, counters: {}, pending: [], seen: [], recent: [], out_of_budget: { open: false, reported_day: null } };
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
  const pending = Array.isArray(j["pending"])
    ? (j["pending"] as Pending[]).filter((x) => isStr(x?.hash) && (x.type === "note" || x.type === "item") && isStr(x.created_at) && typeof x.reads === "number")
    : [];
  const recent = Array.isArray(j["recent"])
    ? (j["recent"] as Recent[]).filter((r) => isStr(r?.author) && isStr(r?.text) && isStr(r?.created_at))
    : [];
  const b = j["out_of_budget"] as Partial<BudgetProblem> | null | undefined;
  const out_of_budget: BudgetProblem = { open: b?.open === true, reported_day: isStr(b?.reported_day) ? b.reported_day : null };
  return { cursor: isStr(j["cursor"]) ? j["cursor"] : null, day, counters, pending, seen, recent, out_of_budget };
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
  author: { identity: string; name?: string };
  voice?: string;
  preview?: string;
  status_note?: unknown;
}

/** An Inbox item, as far as this behavior reads it (spec/digestif-node.json, item_summary and item). */
interface InboxItem {
  id: string;
  hash?: string;
  kind: string;
  subject?: string;
  voice?: string;
  author: { identity: string; name?: string };
  status: string;
  title: string;
  detail?: string;
  created_at: string;
  reviewed_at?: string;
  options?: { id: string; label: string }[];
  answers?: { text: string; author?: { name?: string } }[];
}

export const FEED_LIMIT = 200;

/** Why a message was dropped, or `kept`. */
export type Reason = "kept" | "status_note" | "own" | "not_a_note" | "seen" | "muted" | "duplicate" | "over_budget" | "chain_depth";

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
  const left = (): number => ctx.deadline.getTime() + clock.slept() - wall();

  const request = async (method: string, path: string, params: Record<string, string> = {}, body?: unknown, allow404 = false): Promise<unknown> => {
    if (left() <= 0) throw new DeadlinePassed();
    const url = new URL(`/api/v0/${path}`, base);
    for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
    const res = await fetch(url, {
      method,
      headers: body === undefined ? headers : { ...headers, "content-type": "application/json" },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      signal: AbortSignal.timeout(Math.min(left(), 30_000)),
    });
    if (allow404 && res.status === 404) return null;
    if (!res.ok) throw new Error(`${path}: HTTP ${res.status}`);
    return res.json();
  };
  const get = (path: string, params: Record<string, string> = {}, allow404 = false) => request("GET", path, params, undefined, allow404);
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
  /** The Inbox items that reached the member and no run has reviewed: from anyone but the member and their node. */
  const unreviewedItems = async (self: string): Promise<InboxItem[]> => {
    const body = await get("items", { limit: String(ITEMS_LIMIT) }, true);
    if (body === null) return [];
    if (!Array.isArray(body)) throw new Error("items: not a list");
    return (body as InboxItem[]).filter((i) => i.author.identity !== self && i.voice !== "node" && i.status !== "draft" && i.reviewed_at === undefined);
  };

  try {
    const state = loadState(stateDir, localDay(now));
    const config = loadConfig(stateDir);
    const over = overBudget(state, config);
    let overDrop = false;
    let runProblem = false;
    // A day that starts under budget closes the problem an earlier day opened, unless this run dropped something over budget
    // or reported a run problem: resolving the job without a source would close that one too.
    const settle = async (): Promise<void> => {
      if (options.plan || over || overDrop || runProblem || !state.out_of_budget.open) return;
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
    const members = await get("members");
    const rows = Array.isArray(members) ? (members as { identity?: string; name?: string; is_self?: boolean; muted?: boolean }[]) : [];
    const self = rows.find((m) => m.is_self === true)?.identity;
    if (self === undefined) throw new Error("members: no entry is the member's own");
    const muted = new Set(rows.filter((m) => m.muted === true).map((m) => m.identity));
    const known = new Set(state.seen.map((s) => s.hash));
    const pendingHashes = new Set(state.pending.map((p) => p.hash));
    const items = (await unreviewedItems(self)).filter((i) => i.hash !== undefined && !pendingHashes.has(i.hash));
    if (fresh.length === 0 && items.every((i) => known.has(i.hash!)) && state.pending.length === 0) {
      await settle();
      say("nothing new");
      return 0;
    }
    state.recent = state.recent.filter((r) => now.getTime() - Date.parse(r.created_at) < DEDUPE_WINDOW_MS);
    const nameOf = (identity: string) => rows.find((m) => m.identity === identity)?.name ?? identity;
    const batch: BatchMessage[] = [];
    const add = (m: Omit<BatchMessage, "ref">) => batch.push({ ref: `m${batch.length + 1}`, ...m });
    const kept: Pending[] = [];
    const keep = (hash: string, type: Pending["type"], created_at: string) => {
      known.add(hash);
      state.seen.push({ hash, created_at });
      kept.push({ hash, type, created_at, reads: 0 });
    };
    /** An item in the batch's shape, read in full. */
    const itemMessage = async (id: string): Promise<Omit<BatchMessage, "ref"> | null> => {
      const i = (await get(`items/${encodeURIComponent(id)}`, {}, true)) as InboxItem | null;
      if (i === null || i.hash === undefined) return null;
      return {
        hash: i.hash,
        type: i.kind,
        author: i.author.identity,
        author_name: i.author.name ?? nameOf(i.author.identity),
        voice: i.voice ?? "agent",
        created_at: i.created_at,
        text: [i.title, i.detail ?? ""].filter((t) => t.trim() !== "").join("\n\n"),
        link: new URL(`/inbox/${encodeURIComponent(id)}`, base).href,
        ...(i.subject === undefined ? {} : { subject: i.subject }),
        ...(i.options === undefined || i.options.length === 0 ? {} : { options: i.options.map((o) => o.label) }),
        ...(i.answers === undefined || i.answers.length === 0 ? {} : { answers: i.answers.map((a) => `${a.author?.name ?? "someone"}: ${a.text}`) }),
      };
    };
    const noteMessage = (hash: string, author: string, voice: string, created_at: string, text: string): Omit<BatchMessage, "ref"> => ({
      hash,
      type: "note",
      author,
      author_name: nameOf(author),
      voice,
      created_at,
      text,
      link: new URL(`/feed/${encodeURIComponent(hash)}`, base).href,
    });
    /** The member's own notes that went out in the window, newest first: what they work on and are stuck on. */
    const ownNotes = async (): Promise<OwnNote[]> => {
      const body = (await get("notes", { limit: "10" }, true)) as { notes?: { id?: string; status?: string; shared_at?: string }[] } | null;
      const shared = (body?.notes ?? []).filter(
        (n) => isStr(n.id) && isStr(n.shared_at) && (n.status === "approved" || n.status === "auto_approved") && now.getTime() - Date.parse(n.shared_at) < OWN_NOTES_WINDOW_MS,
      );
      const out: OwnNote[] = [];
      for (const n of shared.slice(0, OWN_NOTES)) {
        const note = (await get(`notes/${encodeURIComponent(n.id!)}`, {}, true)) as { version?: { text?: unknown } } | null;
        const text = note?.version?.text;
        if (isStr(text) && text.trim() !== "") out.push({ shared_at: n.shared_at!, text });
      }
      return out;
    };

    // Notes: oldest first, so of two near-identical notes the earlier is the one kept.
    const notes: { i: FeedItem; text: string }[] = [];
    for (const i of [...fresh].reverse()) {
      let reason: Reason = "kept";
      let text = "";
      let own: Msg | null = null;
      const at = Date.parse(i.created_at);
      if (i.status_note !== undefined && i.status_note !== null) reason = "status_note";
      else if (i.author.identity === self) reason = "own";
      else if (i.kind !== undefined && i.kind !== "summary") reason = "not_a_note";
      else if (known.has(i.hash)) reason = "seen";
      else if (muted.has(i.author.identity)) {
        reason = "muted";
        // The node filters muted members before any agent run; seeing one here means it no longer does.
        say(`a muted member's item ${i.hash} is in the feed; the node should have filtered it`);
      } else {
        // The feed's preview is only the first line; the dedupe compares the message's full text, fetched once.
        own = await message(i.hash);
        text = isStr(own?.text) ? own.text : (i.preview ?? "");
      }
      const folded = foldText(text);
      if (reason !== "kept") {
        /* decided above */
      } else if (folded !== "" && state.recent.some((r) => r.author === i.author.identity && r.text === folded && Math.abs(at - Date.parse(r.created_at)) < DEDUPE_WINDOW_MS)) {
        reason = "duplicate";
      } else if (over) reason = "over_budget";
      else if (await chainTooDeep(i, own)) reason = "chain_depth";
      if (options.plan) {
        (options.out ?? console.log)(`${i.hash} ${reason === "kept" ? "keep" : "drop"} ${reason}`);
        if (reason === "kept") state.recent.push({ author: i.author.identity, text: folded, created_at: i.created_at });
        continue;
      }
      if (reason === "status_note" || reason === "own" || reason === "seen" || reason === "not_a_note") continue;
      if (reason === "over_budget") overDrop = true;
      if (reason !== "kept") {
        known.add(i.hash);
        state.seen.push({ hash: i.hash, created_at: i.created_at });
        continue;
      }
      state.recent.push({ author: i.author.identity, text: folded, created_at: i.created_at });
      keep(i.hash, "note", i.created_at);
      notes.push({ i, text });
    }
    // Items: every one that reached the member and no run has reviewed, oldest first.
    const newItems: InboxItem[] = [];
    for (const i of [...items].sort((a, b) => a.created_at.localeCompare(b.created_at))) {
      const reason: Reason = known.has(i.hash!) ? "seen" : muted.has(i.author.identity) ? "muted" : over ? "over_budget" : "kept";
      if (options.plan) {
        (options.out ?? console.log)(`${i.hash} ${reason === "kept" ? "keep" : "drop"} ${reason}`);
        continue;
      }
      if (reason === "seen") continue;
      if (reason === "over_budget") overDrop = true;
      if (reason !== "kept") {
        known.add(i.hash!);
        state.seen.push({ hash: i.hash!, created_at: i.created_at });
        continue;
      }
      newItems.push(i);
    }
    if (options.plan) {
      for (const p of state.pending) (options.out ?? console.log)(`${p.hash} keep again (read ${p.reads} of ${MAX_READS})`);
      return 0;
    }

    // The batch: what failed before, read again, then what is new.
    const again: Pending[] = [];
    if (!over) {
      for (const p of state.pending) {
        if (p.type === "item") {
          const m = await itemMessage(p.hash);
          if (m !== null) {
            add(m);
            again.push(p);
          }
        } else {
          const m = await message(p.hash);
          if (m !== null) {
            add(noteMessage(p.hash, (m as { author?: { identity?: string } }).author?.identity ?? "", m.voice ?? "agent", p.created_at, m.text ?? ""));
            again.push(p);
          }
        }
      }
    }
    for (const { i, text } of notes) {
      add(noteMessage(i.hash, i.author.identity, i.voice ?? "agent", i.created_at, text));
    }
    for (const i of newItems) {
      const m = await itemMessage(i.id);
      if (m === null) continue;
      add(m);
      keep(i.hash!, "item", i.created_at);
    }
    if (batch.length > 0) {
      state.counters["agent_runs"] = (state.counters["agent_runs"] ?? 0) + 1;
      // The batch is decided once: the state is saved before the run, with every message pending.
      state.pending = [...again, ...kept].map((p) => ({ ...p, reads: p.reads + 1 }));
      saveState(stateDir, state);
      const hookConfig = await readConfig(hookStateDir(ctx.dataDir));
      const textOf = (body: unknown): string => {
        const t = (body as { text?: unknown } | null)?.text;
        return isStr(t) ? t : "";
      };
      const saved = await get("settings/inbox_agent", {}, true);
      const done = await runInbox({
        stateDir,
        harness: harnessOf(hookConfig),
        inboxPrompt: saved === null ? await readFile(INBOX_PROMPT_FILE, "utf8") : textOf(saved),
        brief: textOf(await get("brief")),
        rules: textOf(await get("rules")),
        learnings: textOf(await get("learnings", {}, true)),
        deny: readDenyList(await get("rules/deny", {}, true)),
        allow: [...(hookConfig.allow ?? []), ...rows.map((m) => m.name).filter(isStr)],
        members: rows.filter((m) => isStr(m.identity)).map((m): Member => ({ identity: m.identity!, name: m.name ?? m.identity!, is_self: m.is_self === true })),
        batch,
        ownNotes: await ownNotes(),
        post: async (body) => (await request("POST", "inbox_agent/runs", {}, body)) as Awaited<ReturnType<Parameters<typeof runInbox>[0]["post"]>>,
        log,
      });
      if (done.status === "done") {
        state.pending = [];
        const sent = done.sent + done.items;
        if (sent > 0) state.counters["outbound"] = (state.counters["outbound"] ?? 0) + sent;
        log(`the Inbox agent read ${batch.length}: ${done.sent} answered, ${done.kept} answers kept for the member, ${done.filed} ideas filed, ${done.items} items written`);
      } else {
        runProblem = true;
        const dropped = state.pending.filter((p) => p.reads >= MAX_READS);
        state.pending = state.pending.filter((p) => p.reads < MAX_READS);
        log(`the Inbox agent's run over ${batch.length} failed: ${done.why}`);
        if (dropped.length > 0) log(`read ${MAX_READS} times without a run finishing, left unreviewed: ${dropped.map((p) => p.hash).join(", ")}`);
        const err = await reportProblem(ctx.digestif, "read_circle", done.problem);
        if (err !== undefined) log(`could not report the problem: ${err}`);
      }
    }
    if (overDrop && state.out_of_budget.reported_day !== state.day) {
      const err = await reportProblem(ctx.digestif, "read_circle", "out_of_budget");
      if (err === undefined) state.out_of_budget = { open: true, reported_day: state.day };
      else log(`could not report the out_of_budget problem: ${err}`);
    }
    state.cursor = newest ?? state.cursor;
    saveState(stateDir, state);
    await settle();
    log(`read ${fresh.length} new feed items and ${items.length} unreviewed items, ran over ${batch.length}`);
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
