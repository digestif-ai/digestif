// The nightly run: the pipeline of docs/design.md, The nightly note, at the member's fixed minute.
// extract -> write -> screens -> hand over (`digestif note --text -`), or record a tick when no
// note is handed over. Keyed by local date, so a laptop that was closed posts when it next wakes.
// Until the node spawns behaviors itself (#54), a launchd agent calls this every few minutes and
// the state file below decides whether tonight's note is due.

import { spawn } from "node:child_process";
import { appendFileSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { appendFile, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { AwakeClock } from "./awake.ts";
import { day } from "./day.ts";
import { extractWithFailures, render } from "./extract.ts";
import { modelBusinessScreen, screenNote, type BusinessScreen } from "./screen.ts";
import { chosen, type Source, type SourcesForm } from "./sources.ts";

export interface Selection {
  sources: Source[];
  form?: SourcesForm;
}
import { writeNote, type WriterOptions } from "./writer.ts";

/** Minutes after local midnight: 3:00 to 3:59. */
export const MINUTE_MIN = 180;
export const MINUTE_MAX = 239;
/** No new step starts this close to the node's deadline. */
export const DEADLINE_MARGIN_MS = 60_000;
/**
 * A date's run is tried this many times (a failed or hung writer, a refused hand-over, the node's
 * deadline) and no more. The last failure is recorded with `digestif tick --outcome failed` and its
 * reason, which the Approvals page shows, and the date is over.
 */
export const MAX_ATTEMPTS = 3;
/** `digestif tick --note` takes at most this many characters. */
export const TICK_NOTE_MAX = 280;

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
 *       "signed_out_ticked": "2026-10-30", the date whose harness_signed_out tick is recorded
 *       "covered": "2026-10-28",           the last day a run's digest covered (posted, quiet or
 *                                          refused); the next run also covers the days after it
 *       "command_read": { "command-athena": 1761722460000 }
 *                                          per chosen command source, in epoch milliseconds, the
 *                                          start of its next window, written with `covered`
 *     }
 *
 * Only `version` is required (the minute, when present, is 180..239). In hook mode the node owns the
 * minute and the once-per-date logic: the file keeps only `attempts`, `signed_out_ticked`, `covered` and `command_read`, and
 * lives in `<data_dir>/behaviors/nightly/`. A date is due when it is later than `handled` and the
 * clock has passed `minute` on it.
 */
export interface State {
  version: 1;
  /** Absent in hook mode, where the node owns the minute. */
  minute?: number;
  handled?: string;
  outcome?: "posted" | "quiet" | "refused";
  attempts?: { date: string; count: number };
  signed_out_ticked?: string;
  covered?: string;
  command_read?: Record<string, number>;
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
  if (typeof s !== "object" || s === null || ((s as State).minute !== undefined && !validMinute((s as State).minute))) {
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

/** The local date `n` days after `date`. */
export function addDays(date: string, n: number): string {
  const [y, m, d] = date.split("-").map(Number) as [number, number, number];
  return localDate(new Date(y, m - 1, d + n));
}

/** A run catches up on at most this many days whose own runs never covered them. */
export const MAX_CATCH_UP_DAYS = 7;

/**
 * The first day a run covering `covers` reads: the day after the last one a run covered, so a day
 * whose run failed (or never ran) is not lost, up to MAX_CATCH_UP_DAYS back. With nothing covered
 * yet, only `covers`.
 */
export function catchUpFrom(covered: string | undefined, covers: string): string {
  if (covered === undefined || covered >= covers) return covers;
  const next = addDays(covered, 1);
  const limit = addDays(covers, -MAX_CATCH_UP_DAYS);
  return next > limit ? next : limit;
}

/**
 * The start of each command source's window for a run covering `covers`: where its last run left
 * it, never more than MAX_CATCH_UP_DAYS back. A source with no entry reads from the run's window.
 */
export function commandSince(read: Record<string, number> | undefined, covers: string): Record<string, number> {
  const oldest = day(addDays(covers, -MAX_CATCH_UP_DAYS)).start;
  return Object.fromEntries(Object.entries(read ?? {}).map(([id, at]) => [id, Math.max(at, oldest)]));
}

/** The run log's path for a date. */
export const logFile = (stateDir: string, date: string) => join(stateDir, "logs", `nightly-${date}.log`);

/** Appends one line to the date's run log, synchronously (a signal handler uses it before exiting). */
export function logLineSync(stateDir: string, date: string, msg: string, at = new Date()): void {
  mkdirSync(join(stateDir, "logs"), { recursive: true });
  appendFileSync(logFile(stateDir, date), `${at.toISOString()} ${msg}\n`);
}

/**
 * Counts a failed try of `date`, synchronously, for a run the node ends at its deadline: the try is
 * spent like any other failure. Answers the count.
 */
export function countFailureSync(stateDir: string, date: string): number {
  let st: State = { version: 1 };
  try {
    st = JSON.parse(readFileSync(stateFile(stateDir), "utf8")) as State;
  } catch {
    /* no state yet */
  }
  const count = (st.attempts?.date === date ? st.attempts.count : 0) + 1;
  mkdirSync(stateDir, { recursive: true });
  const tmp = stateFile(stateDir) + ".tmp";
  writeFileSync(tmp, JSON.stringify({ ...st, attempts: { date, count } }, null, 2) + "\n");
  renameSync(tmp, stateFile(stateDir));
  return count;
}

/** The state directory in hook mode: `<data_dir>/behaviors/nightly/`. */
export const hookStateDir = (dataDir: string) => join(dataDir, "behaviors", "nightly");

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
  /**
   * Hook mode: the node's `local_date`. The node owns the minute and the once-per-date logic, so the
   * state's minute and `handled` are neither checked nor written; `now` is the clock for the log only.
   */
  hookDate?: string;
  /**
   * When the node ends the run, if the machine stays awake. The node measures its deadline on a clock
   * that stops while the machine sleeps, so the run does too: no step starts once less than
   * DEADLINE_MARGIN_MS of the awake time left at the start remains.
   */
  deadline?: Date;
  /** The wall clock the run's awake clock reads; tests move it to stand in for a sleep. */
  wall?: () => number;
  /** Called as each step starts: extract, write, screen, hand over. */
  onStep?: (step: string) => void;
  /** What ~ expands to in source paths. */
  home?: string;
  /** Names of the circle's members and agents the PII screen allows. */
  allow?: string[];
  writer?: WriterOptions;
  /** The business-information screen; by default the writer's harness answers it (src/screen.ts). */
  business?: BusinessScreen;
  /** Brief and rules, read when the writer's options carry none. */
  context?: () => Promise<{ brief: string; rules: string }>;
}

export type NightlyResult =
  | { status: "not_due"; date: string; minute: number }
  | { status: "already_handled"; date: string }
  | { status: "gave_up"; date: string; message?: string }
  | { status: "posted"; date: string }
  | { status: "quiet"; date: string }
  | { status: "refused"; date: string; rule: string }
  | { status: "signed_out"; date: string }
  | { status: "failed"; date: string; message: string }
  | { status: "dry_run"; date: string; note?: string; refused?: string };

/** One firing of the nightly run: does whatever is due for `now`, once. */
export async function nightly(o: NightlyOptions): Promise<NightlyResult> {
  const clock = new AwakeClock(o.wall).start();
  try {
    return await run(o, clock);
  } finally {
    clock.stop();
    const slept = clock.slept();
    if (slept > 0 && !o.dryRun) {
      logLineSync(o.stateDir, o.hookDate ?? localDate(o.now), `the machine slept ${Math.round(slept / 1000)} seconds during the run; not counted against it`);
    }
  }
}

async function run(o: NightlyOptions, clock: AwakeClock): Promise<NightlyResult> {
  const wall = o.wall ?? Date.now;
  const budget = o.deadline === undefined ? undefined : o.deadline.getTime() - wall();
  const date = o.hookDate ?? localDate(o.now);
  const hook = o.hookDate !== undefined;
  const node = o.node ?? "digestif";
  // A dry run records nothing, the log included.
  const log = async (msg: string) => {
    if (o.dryRun) return;
    await mkdir(join(o.stateDir, "logs"), { recursive: true });
    await appendFile(logFile(o.stateDir, date), `${o.now.toISOString()} ${msg}\n`);
  };

  let state = await readState(o.stateDir);
  if (hook) {
    state ??= { version: 1 };
    if (state.attempts?.date === date && state.attempts.count >= MAX_ATTEMPTS) return { status: "gave_up", date };
  } else if (!o.dryRun) {
    if (state === undefined || state.minute === undefined) {
      const minute = o.minute ?? MINUTE_MIN + Math.floor(Math.random() * (MINUTE_MAX - MINUTE_MIN + 1));
      if (!validMinute(minute)) throw new Error(`the minute is ${MINUTE_MIN}..${MINUTE_MAX} (minutes after midnight)`);
      state = { ...state, version: 1, minute };
      await saveState(o.stateDir, state);
      await log(`minute chosen: ${minute}`);
    }
    if (state.handled !== undefined && state.handled >= date) return { status: "already_handled", date };
    if (minutesOfDay(o.now) < state.minute!) return { status: "not_due", date, minute: state.minute! };
    if (state.attempts?.date === date && state.attempts.count >= MAX_ATTEMPTS) return { status: "gave_up", date };
  }
  const st: State = state ?? { version: 1 };
  // The node's deadline, in awake time: no step starts inside the margin before it. A step already
  // running is the node's SIGTERM to end.
  const begin = (step: string): string | undefined => {
    o.onStep?.(step);
    return budget !== undefined && clock.read() >= budget - DEADLINE_MARGIN_MS ? `the deadline is near; not starting ${step}` : undefined;
  };

  // A failed try is retried on the node's next pass (hook mode) or the next firing; the last one ends
  // the date, saying why where the member looks: the Approvals page and the digest.
  const fail = async (message: string): Promise<NightlyResult> => {
    const count = (st.attempts?.date === date ? st.attempts.count : 0) + 1;
    await saveState(o.stateDir, { ...st, attempts: { date, count } });
    await log(`failed (try ${count}/${MAX_ATTEMPTS}): ${message}`);
    if (count < MAX_ATTEMPTS || o.dryRun) return { status: "failed", date, message };
    const note = `The nightly note failed ${MAX_ATTEMPTS} times; the last try: ${message}`;
    const err = (await tick("failed", note.length <= TICK_NOTE_MAX ? note : `${note.slice(0, TICK_NOTE_MAX - 1)}…`)) && (await tick("failed"));
    await log(err === undefined ? "gave up for the date: tick failed" : `gave up for the date; the failed tick was not recorded: ${err}`);
    return { status: "gave_up", date, message };
  };
  const covers = previousDate(date);
  // Replaces the last run's: a source no longer chosen is not read while it is not, so its window
  // starts over if it is chosen again.
  let commandRead: Record<string, number> = {};
  const finish = async (outcome: "posted" | "quiet" | "refused") => {
    const { attempts: _dropped, command_read: _replaced, ...rest } = st;
    const covered = { ...rest, covered: covers, ...(Object.keys(commandRead).length === 0 ? {} : { command_read: commandRead }) };
    await saveState(o.stateDir, hook ? covered : { ...covered, handled: date, outcome });
  };
  const tick = async (outcome: "quiet" | "harness_signed_out" | "failed", note?: string): Promise<string | undefined> => {
    const r = await runNode(node, ["tick", "--outcome", outcome, ...(note === undefined ? [] : ["--note", note])]);
    return r.code === 0 ? undefined : `digestif tick exited ${r.code}: ${r.stderr.trim().slice(0, 200)}`;
  };

  // 1. Extract: the note tells about the local day before the key date (the day that ended at
  //    midnight), so a catch-up after sleep covers the same day a punctual run would.
  let late = begin("extract");
  if (late !== undefined) return fail(late);
  //    A day no run covered (every try failed, or the harness was signed out) is read too.
  const from = catchUpFrom(st.covered, covers);
  const window = { ...day(covers), start: day(from).start };
  if (from < covers) await log(`also covers ${from} to ${previousDate(covers)}: no run covered them`);
  const extracted = await extractWithFailures(chosen(o.selection.sources, o.selection.form), window, {
    ...(o.home === undefined ? {} : { home: o.home }),
    commandSince: commandSince(st.command_read, covers),
    now: wall,
  });
  commandRead = extracted.commandRead;
  const lines = render(extracted.lines);
  await log(`extracted ${lines.length} lines of ${covers}`);
  for (const f of extracted.failures) await log(`source failed: ${f}`);

  if (lines.length === 0) {
    if (o.dryRun) return { status: "dry_run", date };
    // A failed command source is named, never its output, so the silence report says why.
    const err = await tick("quiet", extracted.failures.length === 0 ? undefined : `no lines from ${extracted.failures.join("; ")}`);
    if (err !== undefined) return fail(err);
    await finish("quiet");
    await log("nothing to say: tick quiet");
    return { status: "quiet", date };
  }

  // 2. Write.
  late = begin("write");
  if (late !== undefined) return fail(late);
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
  if (w.status === "hung") return fail(`the writer wrote nothing for ${Math.round(w.quietMs / 60_000)} minutes of awake time`);
  if (w.status !== "note") return fail(w.status === "failed" ? w.message : `the writer ended with ${w.status}`);

  // 3. Screens: the PII deny layer, then the business-information screen.
  late = begin("screen");
  if (late !== undefined) return fail(late);
  const business = o.business ?? modelBusinessScreen(o.writer ?? {});
  const verdict = await screenNote(w.note, { allow: o.allow ?? [], business });
  if (verdict.outcome === "refused") {
    await log(`refused: ${verdict.rule}`);
    if (o.dryRun) return { status: "dry_run", date, refused: verdict.rule };
    // The rule's name, never the note's text: the Members page and the digest say why the night is silent.
    const err = await tick("quiet", `refused by the deny layer: ${verdict.rule}`);
    if (err !== undefined) return fail(err);
    await finish("refused");
    return { status: "refused", date, rule: verdict.rule };
  }
  if (verdict.outcome === "held") await log(`held for approval: ${verdict.reason}`);
  if (o.dryRun) return { status: "dry_run", date, note: w.note };

  // 4. Hand over. A held note goes over with its reason, and the node keeps it for its person
  //    whatever their approval settings: a flag is never sent without review.
  late = begin("hand over");
  if (late !== undefined) return fail(late);
  const hold = verdict.outcome === "held" ? ["--hold", verdict.reason] : [];
  const r = await runNode(node, ["note", "--text", "-", ...hold], w.note + "\n");
  if (r.code !== 0) return fail(`digestif note exited ${r.code}: ${r.stderr.trim().slice(0, 200)}`);
  await finish("posted");
  await log("note handed over");
  return { status: "posted", date };
}
