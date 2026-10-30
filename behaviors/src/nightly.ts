// The nightly run: the pipeline of docs/design.md, The nightly note, at the member's fixed minute.
// extract -> write -> screens -> hand over (`digestif note --text -`), or record a tick when no
// note is handed over. Keyed by local date, so a laptop that was closed posts when it next wakes.
// Until the node spawns behaviors itself (#54), a launchd agent calls this every few minutes and
// the state file below decides whether tonight's note is due.

import { spawn } from "node:child_process";
import { appendFile, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { day } from "./day.ts";
import { extract, render } from "./extract.ts";
import { screenNote, type BusinessScreen } from "./screen.ts";
import { chosen, type Source, type SourcesForm } from "./sources.ts";

export interface Selection {
  sources: Source[];
  form?: SourcesForm;
}
import { writeNote, type WriterOptions } from "./writer.ts";

/** Minutes after local midnight: 3:00 to 3:59. */
export const MINUTE_MIN = 180;
export const MINUTE_MAX = 239;
/** A date's writer is tried this many times (a failure, a timeout, a refused hand-over) and no more. */
export const MAX_ATTEMPTS = 3;

/**
 * The state file, `nightly.json` in the state directory:
 *
 *     {
 *       "version": 1,
 *       "minute": 207,                     chosen once, 180..239, minutes after local midnight
 *       "handled": "2026-10-29",           the last local date whose run is over (note handed over,
 *                                          nothing to say, or the note refused)
 *       "outcome": "posted",               posted | quiet | refused, for `handled`
 *       "attempts": { "date": "2026-10-30", "count": 1 },   failed tries of a date not yet handled
 *       "signed_out_ticked": "2026-10-30"  the date whose harness_signed_out tick is recorded
 *     }
 *
 * Only `version` and `minute` are required. A date is due when it is later than `handled` and the
 * clock has passed `minute` on it.
 */
export interface State {
  version: 1;
  minute: number;
  handled?: string;
  outcome?: "posted" | "quiet" | "refused";
  attempts?: { date: string; count: number };
  signed_out_ticked?: string;
}

export function validMinute(n: unknown): n is number {
  return typeof n === "number" && Number.isInteger(n) && n >= MINUTE_MIN && n <= MINUTE_MAX;
}

export function stateFile(stateDir: string): string {
  return join(stateDir, "nightly.json");
}

/** The default state directory: `behaviors` inside the node's data directory. */
export function defaultStateDir(env: NodeJS.ProcessEnv = process.env, platform = process.platform): string {
  const base =
    env["DIGESTIF_HOME"] ||
    (platform === "darwin"
      ? join(homedir(), "Library", "Application Support", "Digestif")
      : join(env["XDG_DATA_HOME"] || join(homedir(), ".local", "share"), "digestif"));
  return join(base, "behaviors");
}

export async function readState(stateDir: string): Promise<State | undefined> {
  let raw: string;
  try {
    raw = await readFile(stateFile(stateDir), "utf8");
  } catch {
    return undefined;
  }
  const s: unknown = JSON.parse(raw);
  if (typeof s !== "object" || s === null || !validMinute((s as State).minute)) {
    throw new Error(`${stateFile(stateDir)}: not a nightly state (minute must be ${MINUTE_MIN}..${MINUTE_MAX})`);
  }
  return s as State;
}

async function saveState(stateDir: string, s: State): Promise<void> {
  await mkdir(stateDir, { recursive: true });
  const tmp = stateFile(stateDir) + ".tmp";
  await writeFile(tmp, JSON.stringify(s, null, 2) + "\n");
  await rename(tmp, stateFile(stateDir));
}

const p2 = (n: number) => String(n).padStart(2, "0");
export const localDate = (d: Date) => `${d.getFullYear()}-${p2(d.getMonth() + 1)}-${p2(d.getDate())}`;
export const minutesOfDay = (d: Date) => d.getHours() * 60 + d.getMinutes();
/** The local date before `date`: the day a note keyed by `date` tells about. */
export function previousDate(date: string): string {
  const [y, m, d] = date.split("-").map(Number) as [number, number, number];
  return localDate(new Date(y, m - 1, d - 1));
}

interface Ran {
  code: number | null;
  stdout: string;
  stderr: string;
}

/** Runs the node binary. */
export function runNode(bin: string, args: string[], input = ""): Promise<Ran> {
  return new Promise((resolve) => {
    const child = spawn(bin, args, { stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8").on("data", (d: string) => (stdout += d));
    child.stderr.setEncoding("utf8").on("data", (d: string) => (stderr += d));
    child.on("error", (e) => resolve({ code: null, stdout, stderr: stderr + e.message }));
    child.on("close", (code) => resolve({ code, stdout, stderr }));
    child.stdin.on("error", () => {});
    child.stdin.end(input);
  });
}

export interface NightlyOptions {
  stateDir: string;
  selection: Selection;
  /** The clock. */
  now: Date;
  /** The `minute` setting, used only when the state file has none yet. A random one when absent. */
  minute?: number;
  /** The node binary: `digestif` on PATH by default. */
  node?: string;
  dryRun?: boolean;
  /** What ~ expands to in source paths. */
  home?: string;
  /** Names of the circle's members and agents the PII screen allows. */
  allow?: string[];
  writer?: WriterOptions;
  /** The business-information screen; the default holds nothing. */
  business?: BusinessScreen;
  /** Brief and rules, read when the writer's options carry none. */
  context?: () => Promise<{ brief: string; rules: string }>;
}

export type NightlyResult =
  | { status: "not_due"; date: string; minute: number }
  | { status: "already_handled"; date: string }
  | { status: "gave_up"; date: string }
  | { status: "posted"; date: string }
  | { status: "quiet"; date: string }
  | { status: "refused"; date: string; rule: string }
  | { status: "signed_out"; date: string }
  | { status: "failed"; date: string; message: string }
  | { status: "dry_run"; date: string; note?: string; refused?: string };

/** One firing of the nightly run: does whatever is due for `now`, once. */
export async function nightly(o: NightlyOptions): Promise<NightlyResult> {
  const date = localDate(o.now);
  const node = o.node ?? "digestif";
  const log = async (msg: string) => {
    await mkdir(join(o.stateDir, "logs"), { recursive: true });
    await appendFile(join(o.stateDir, "logs", `nightly-${date}.log`), `${o.now.toISOString()} ${msg}\n`);
  };

  let state = await readState(o.stateDir);
  if (!o.dryRun) {
    if (state === undefined) {
      const minute = o.minute ?? MINUTE_MIN + Math.floor(Math.random() * (MINUTE_MAX - MINUTE_MIN + 1));
      if (!validMinute(minute)) throw new Error(`the minute is ${MINUTE_MIN}..${MINUTE_MAX} (minutes after midnight)`);
      state = { version: 1, minute };
      await saveState(o.stateDir, state);
      await log(`minute chosen: ${minute}`);
    }
    if (state.handled !== undefined && state.handled >= date) return { status: "already_handled", date };
    if (minutesOfDay(o.now) < state.minute) return { status: "not_due", date, minute: state.minute };
    if (state.attempts?.date === date && state.attempts.count >= MAX_ATTEMPTS) return { status: "gave_up", date };
  }
  const st: State = state ?? { version: 1, minute: MINUTE_MIN };

  const fail = async (message: string): Promise<NightlyResult> => {
    const count = (st.attempts?.date === date ? st.attempts.count : 0) + 1;
    await saveState(o.stateDir, { ...st, attempts: { date, count } });
    await log(`failed (try ${count}/${MAX_ATTEMPTS}): ${message}`);
    return { status: "failed", date, message };
  };
  const finish = async (outcome: "posted" | "quiet" | "refused") => {
    const { attempts: _dropped, ...rest } = st;
    await saveState(o.stateDir, { ...rest, handled: date, outcome });
  };
  const tick = async (outcome: "quiet" | "harness_signed_out"): Promise<string | undefined> => {
    const r = await runNode(node, ["tick", "--outcome", outcome]);
    return r.code === 0 ? undefined : `digestif tick exited ${r.code}: ${r.stderr.trim().slice(0, 200)}`;
  };

  // 1. Extract: the note tells about the local day before the key date (the day that ended at
  //    midnight), so a catch-up after sleep covers the same day a punctual run would.
  const covers = previousDate(date);
  const lines = render(await extract(chosen(o.selection.sources, o.selection.form), day(covers), o.home === undefined ? {} : { home: o.home }));
  await log(`extracted ${lines.length} lines of ${covers}`);

  if (lines.length === 0) {
    if (o.dryRun) return { status: "dry_run", date };
    const err = await tick("quiet");
    if (err !== undefined) return fail(err);
    await finish("quiet");
    await log("nothing to say: tick quiet");
    return { status: "quiet", date };
  }

  // 2. Write.
  const ctx = o.writer?.brief === undefined && o.writer?.rules === undefined && o.context ? await o.context().catch(() => undefined) : undefined;
  const w = await writeNote(lines, { ...o.writer, ...(ctx ?? {}) });
  if (w.status === "signed_out") {
    await log("the harness has no login");
    if (o.dryRun) return { status: "signed_out", date };
    if (st.signed_out_ticked !== date) {
      const err = await tick("harness_signed_out");
      if (err !== undefined) return fail(err);
      await saveState(o.stateDir, { ...st, signed_out_ticked: date });
    }
    return { status: "signed_out", date };
  }
  if (w.status !== "note") return fail(w.status === "failed" ? w.message : `the writer ended with ${w.status}`);

  // 3. Screens: the PII deny layer, then the business-information hook (a no-op until it lands).
  const verdict = await screenNote(w.note, { allow: o.allow ?? [], ...(o.business === undefined ? {} : { business: o.business }) });
  if (verdict.outcome === "refused") {
    await log(`refused: ${verdict.rule}`);
    if (o.dryRun) return { status: "dry_run", date, refused: verdict.rule };
    const err = await tick("quiet");
    if (err !== undefined) return fail(err);
    await finish("refused");
    return { status: "refused", date, rule: verdict.rule };
  }
  if (verdict.outcome === "held") await log(`held for approval: ${verdict.reason}`);
  if (o.dryRun) return { status: "dry_run", date, note: w.note };

  // 4. Hand over. A held note goes over too: the node's local UI holds it for approval.
  const r = await runNode(node, ["note", "--text", "-"], w.note + "\n");
  if (r.code !== 0) return fail(`digestif note exited ${r.code}: ${r.stderr.trim().slice(0, 200)}`);
  await finish("posted");
  await log("note handed over");
  return { status: "posted", date };
}
