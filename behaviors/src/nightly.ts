// The note's work run: the pipeline of docs/design.md, The note, at the member's Note time.
// read -> write -> checks -> hand over (`digestif note --text - --checks <runs> --ends <file>`), or
// record a quiet tick when there is nothing to say. A failure is reported to the node's one problem
// record (`digestif problem report`), never in words of the run's own. Keyed by local date, so a
// laptop that was closed runs when it next wakes. The node spawns it as its nightly hook at Note
// time and hands over where each source starts (src/hook.ts); run standalone (a launchd agent
// calling it every few minutes), the state file below decides whether the date's run is due and
// keeps each source's point itself.

import { spawn } from "node:child_process";
import { appendFileSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { appendFile, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { AwakeClock } from "./awake.ts";
import { readRecord } from "./extract.ts";
import { authorKey, repositoryKey, sourceKey, type End, type Start } from "./record.ts";
import { modelPiiCheck, modelRulesCheck, runChecks, type ModelCheck } from "./checks.ts";
import type { DenyEntry } from "./deny.ts";
import { chosen, type Source, type SourcesForm } from "./sources.ts";

export interface Selection {
  sources: Source[];
  form?: SourcesForm;
}
import { writeNote, type WriterOptions } from "./writer.ts";

/** The Note time a standalone run uses when none is given: the node's default (node/web/store.ml, Settings). */
export const DEFAULT_NOTE_TIME = "07:00";
/** No new step starts this close to the node's deadline. */
export const DEADLINE_MARGIN_MS = 60_000;
/**
 * A date's run is tried this many times (a failed or hung writer, a refused hand-over, the node's
 * deadline) and no more. Each failure is a problem in writing the note, which the header of Notes
 * shows until a note is written; after the last the date is over.
 */
export const MAX_ATTEMPTS = 3;

/** The node's problem record (docs/design.md, One way a failure is reported): its jobs and kinds. */
export type ProblemJob = "write_version" | "pii_check" | "rules_check" | "source" | "learnings";
export type ProblemKind = "signed_out" | "model_unavailable" | "out_of_budget" | "source_failed" | "failed";

/** Reports a job's failure to the node: the one function every job calls. Answers why it could not. */
export async function reportProblem(bin: string, job: ProblemJob, kind: ProblemKind, source?: string): Promise<string | undefined> {
  const r = await runNode(bin, ["problem", "report", "--job", job, "--kind", kind, ...(source === undefined ? [] : ["--source", source])]);
  return r.code === 0 ? undefined : `digestif problem exited ${r.code}: ${r.stderr.trim().slice(0, 200)}`;
}

/** The job succeeded: its open problems close. */
export async function resolveProblem(bin: string, job: ProblemJob, source?: string): Promise<string | undefined> {
  const r = await runNode(bin, ["problem", "resolve", "--job", job, ...(source === undefined ? [] : ["--source", source])]);
  return r.code === 0 ? undefined : `digestif problem exited ${r.code}: ${r.stderr.trim().slice(0, 200)}`;
}

/**
 * The state file, `nightly.json` in the state directory:
 *
 *     {
 *       "version": 1,
 *       "note_time": "07:00",              standalone: the Note time, HH:MM in the machine's zone
 *       "handled": "2026-10-29",           standalone: the last local date whose run is over (note
 *                                          handed over, or nothing to say)
 *       "outcome": "posted",               posted | quiet, for `handled`
 *       "attempts": { "date": "2026-10-30", "count": 1 },   failed tries of a date not yet handled
 *       "record": { "source:claude-code": { "at": 1761722460000 } }
 *                                          standalone: each source's point, the end of the last
 *                                          note handed over, which stands in for its approval
 *     }
 *
 * Only `version` is required. In hook mode the node owns Note time, the once-per-date logic and
 * each source's point: the file keeps only `attempts`, and lives in
 * `<data_dir>/behaviors/nightly/`. A date is due when it is later than `handled` and the clock has
 * passed Note time on it.
 */
export interface State {
  version: 1;
  note_time?: string;
  handled?: string;
  /** "refused" is a state an older run wrote, when the deny layer refused notes. */
  outcome?: "posted" | "quiet" | "refused";
  attempts?: { date: string; count: number };
  record?: Record<string, End>;
}

/** HH:MM, or H:MM, as minutes after local midnight; undefined when it is not a time of day. */
export function noteTimeMinutes(t: unknown): number | undefined {
  if (typeof t !== "string") return undefined;
  const m = /^(\d{1,2}):(\d{2})$/.exec(t.trim());
  if (!m) return undefined;
  const h = Number(m[1]);
  const min = Number(m[2]);
  return h < 24 && min < 60 ? h * 60 + min : undefined;
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
  if (typeof s !== "object" || s === null || Array.isArray(s)) throw new Error(`${stateFile(stateDir)}: not a nightly state`);
  // A state written before Note time carries the minute and the covered days; neither is read.
  const { minute: _minute, covered: _covered, command_read: _read, ...rest } = s as State & { minute?: unknown; covered?: unknown; command_read?: unknown };
  return rest;
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
/**
 * Each chosen source's start for a standalone run, from the points the state keeps: the point, else
 * the 24 hours before now, which is where a source added since the last note starts.
 */
export function standaloneStarts(sources: Source[], record: Record<string, End> | undefined): Source[] {
  const startOf = (key: string): Start => {
    const p = record?.[key];
    return p === undefined ? { recorded: false } : { start: p.at, recorded: true, ...(p.sha === undefined ? {} : { sha: p.sha }) };
  };
  return sources.map((s) => {
    if (s.kind !== "git") return { ...s, ...startOf(sourceKey(s.id)) };
    const repositories = (s.repositories ?? s.paths.map((p) => ({ id: p, name: p.split("/").pop() ?? p, paths: [p], recorded: false }))).map((r) => ({ ...r, ...startOf(repositoryKey(r.id)) }));
    const authors = s.authors === null || s.authors === undefined ? s.authors : s.authors.map((a) => ({ ...a, ...startOf(authorKey(a.email)) }));
    return { ...s, repositories, ...(authors === undefined ? {} : { authors }) };
  });
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
  /** Standalone: the Note time, HH:MM; else the state's, else DEFAULT_NOTE_TIME. Saved in the state. */
  noteTime?: string;
  /** The node binary: `digestif` on PATH by default. */
  node?: string;
  dryRun?: boolean;
  /**
   * Hook mode: the node's `local_date`. The node owns Note time and the once-per-date logic, so the
   * state's Note time and `handled` are neither checked nor written; `now` is the clock for the log only.
   */
  hookDate?: string;
  /**
   * Hook mode: no note has been approved yet (the handoff's `first_note`). Its sources carry where
   * each starts, and the note goes over with `--ends`, so approval moves each source there.
   */
  firstNote?: boolean;
  /** The clock the record is read at, epoch milliseconds; `now` when absent. Tests move it. */
  recordNow?: () => number;
  /**
   * When the node ends the run, if the machine stays awake. The node measures its deadline on a clock
   * that stops while the machine sleeps, so the run does too: no step starts once less than
   * DEADLINE_MARGIN_MS of the awake time left at the start remains.
   */
  deadline?: Date;
  /** The wall clock the run's awake clock reads; tests move it to stand in for a sleep. */
  wall?: () => number;
  /** Called as each step starts: read, write, check, hand over. */
  onStep?: (step: string) => void;
  /** What ~ expands to in source paths. */
  home?: string;
  /** Names of the circle's members and agents, which the checks never remove. */
  allow?: string[];
  writer?: WriterOptions;
  /** The member's deny list, when the context does not carry it. */
  deny?: DenyEntry[];
  /** The PII check's model; by default the writer's harness answers it (src/checks.ts). */
  pii?: ModelCheck;
  /** The Rules check; by default the writer's harness answers it over the rules and Learnings. */
  rules?: ModelCheck;
  /** Brief, rules, Learnings and the deny list, read from the node. */
  context?: () => Promise<{ brief: string; rules: string; learnings?: string; deny?: DenyEntry[] }>;
  /** Whether the member saved auto approval, read after writing; absent or failing is no. */
  autoApprove?: () => Promise<boolean>;
}

export type NightlyResult =
  | { status: "not_due"; date: string; noteTime: string }
  | { status: "already_handled"; date: string }
  | { status: "gave_up"; date: string; message?: string }
  | { status: "posted"; date: string }
  | { status: "quiet"; date: string }
  | { status: "emptied"; date: string }
  | { status: "signed_out"; date: string }
  /** A check could not finish: the note went to the node unseen, and its checks run again. */
  | { status: "unchecked"; date: string }
  | { status: "failed"; date: string; message: string }
  | { status: "dry_run"; date: string; note?: string };

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
    const noteTime = o.noteTime ?? state?.note_time ?? DEFAULT_NOTE_TIME;
    const at = noteTimeMinutes(noteTime);
    if (at === undefined) throw new Error(`the Note time is HH:MM, not ${JSON.stringify(noteTime)}`);
    if (state?.note_time !== noteTime) {
      state = { ...state, version: 1, note_time: noteTime };
      await saveState(o.stateDir, state);
    }
    if (state.handled !== undefined && state.handled >= date) return { status: "already_handled", date };
    if (minutesOfDay(o.now) < at) return { status: "not_due", date, noteTime };
    if (state.attempts?.date === date && state.attempts.count >= MAX_ATTEMPTS) return { status: "gave_up", date };
  }
  const st: State = state ?? { version: 1 };
  // The node's deadline, in awake time: no step starts inside the margin before it. A step already
  // running is the node's SIGTERM to end.
  const begin = (step: string): string | undefined => {
    o.onStep?.(step);
    return budget !== undefined && clock.read() >= budget - DEADLINE_MARGIN_MS ? `the deadline is near; not starting ${step}` : undefined;
  };

  // Every failure is reported to the node's problem record by its job and kind; the run's own
  // words stay in its log. A problem the node cannot take is logged, and changes nothing else.
  const report = async (job: ProblemJob, kind: ProblemKind, source?: string): Promise<void> => {
    if (o.dryRun) return;
    const err = await reportProblem(node, job, kind, source);
    if (err !== undefined) await log(`the problem was not recorded: ${err}`);
  };
  const resolve = async (job: ProblemJob, source?: string): Promise<void> => {
    if (o.dryRun) return;
    const err = await resolveProblem(node, job, source);
    if (err !== undefined) await log(`the problem was not closed: ${err}`);
  };
  // A failed try is a problem in writing the note, and is retried on the node's next pass (hook mode)
  // or the next firing; the last one ends the date.
  const fail = async (message: string, kind: ProblemKind = "failed"): Promise<NightlyResult> => {
    const count = (st.attempts?.date === date ? st.attempts.count : 0) + 1;
    await saveState(o.stateDir, { ...st, attempts: { date, count } });
    await log(`failed (try ${count}/${MAX_ATTEMPTS}): ${message}`);
    await report("write_version", kind);
    if (count < MAX_ATTEMPTS || o.dryRun) return { status: "failed", date, message };
    await log("gave up for the date");
    return { status: "gave_up", date, message };
  };
  // Standalone, a note handed over stands in for its approval: each source starts at its end.
  let ends: Record<string, End> = {};
  const finish = async (outcome: "posted" | "quiet") => {
    const { attempts: _dropped, ...rest } = st;
    const record = !hook && outcome === "posted" ? { record: { ...st.record, ...ends } } : {};
    await saveState(o.stateDir, hook ? rest : { ...rest, ...record, handled: date, outcome });
  };
  // Where the note ends, per source: the node moves each source there when the note is approved.
  // A node whose handoff carried no first_note has no --ends.
  const endsArg = async (): Promise<string[]> => {
    if (!hook || o.firstNote === undefined) return [];
    const file = join(o.stateDir, "ends.json");
    await mkdir(o.stateDir, { recursive: true });
    await writeFile(file, JSON.stringify(Object.fromEntries(Object.entries(ends).map(([k, e]) => [k, { at: new Date(e.at).toISOString(), ...(e.sha === undefined ? {} : { sha: e.sha }) }]))) + "\n");
    return ["--ends", file];
  };
  const tick = async (): Promise<string | undefined> => {
    const r = await runNode(node, ["tick"]);
    return r.code === 0 ? undefined : `digestif tick exited ${r.code}: ${r.stderr.trim().slice(0, 200)}`;
  };

  // 1. Read the record: per source from where the last approved note ended (the node's starts in
  //    hook mode, the state's points standalone), the first note's reach before any is approved.
  let late = begin("read");
  if (late !== undefined) return fail(late);
  const picked = chosen(o.selection.sources, o.selection.form);
  const firstNote = hook ? (o.firstNote ?? true) : st.record === undefined;
  const extracted = await readRecord(hook ? picked : standaloneStarts(picked, st.record), {
    firstNote,
    ...(o.home === undefined ? {} : { home: o.home }),
    now: o.recordNow ?? (() => o.now.getTime()),
  });
  ends = extracted.ends;
  const lines = extracted.lines;
  const waiting = extracted.read - extracted.items.length;
  await log(`read ${extracted.items.length} items${firstNote ? " for the first note" : ""}${waiting > 0 ? `; ${waiting} wait for the next note` : ""}`);
  for (const f of extracted.failures) await log(`source failed: ${f}`);
  // Each source is a job of its own: one that failed is its problem, named by its label and never
  // by its output, and one that read closes its own.
  for (const label of extracted.failedSources) await report("source", "source_failed", label);
  for (const label of extracted.readSources) await resolve("source", label);

  if (lines.length === 0) {
    if (o.dryRun) return { status: "dry_run", date };
    const err = await tick();
    if (err !== undefined) return fail(err);
    await resolve("write_version");
    await finish("quiet");
    await log("nothing to say: tick quiet");
    return { status: "quiet", date };
  }

  // 2. Write.
  late = begin("write");
  if (late !== undefined) return fail(late);
  const context = o.context ? await o.context().catch(() => undefined) : undefined;
  const ctx = o.writer?.brief === undefined && o.writer?.rules === undefined && context ? { brief: context.brief, rules: context.rules } : undefined;
  const learned = context?.learnings ?? "";
  const w = await writeNote(lines, { ...o.writer, ...(ctx ?? {}), learnings: learned });
  if (w.status === "signed_out") {
    await log("the harness has no login");
    if (o.dryRun) return { status: "signed_out", date };
    await report("write_version", "signed_out");
    return { status: "signed_out", date };
  }
  if (w.status === "hung") return fail(`the writer wrote nothing for ${Math.round(w.quietMs / 60_000)} minutes of awake time`, "model_unavailable");
  if (w.status !== "note") return fail(w.status === "failed" ? w.message : `the writer ended with ${w.status}`);

  // 3. Check: the PII check and the Rules check remove what they find, again and again, until a
  //    run removes nothing (src/checks.ts). Nothing is refused or held here: what goes over is
  //    the checked text, and the node's signing backstop reads it again.
  late = begin("check");
  if (late !== undefined) return fail(late);
  const harness = o.writer ?? {};
  const checked = await runChecks(w.note, {
    allow: o.allow ?? [],
    deny: o.deny ?? context?.deny ?? [],
    pii: o.pii ?? modelPiiCheck(harness),
    rules: o.rules ?? modelRulesCheck({ ...harness, rules: o.writer?.rules ?? context?.rules ?? "", learnings: context?.learnings ?? "" }),
  });
  for (const run of checked.runs) {
    const what = run.removals.map((r) => `${r.count} from ${r.part} (${r.detector ?? r.cause})`).join(", ");
    await log(`${run.check} check: ${what === "" ? "removed nothing" : `removed ${what}`}`);
  }
  // A check that cannot finish leaves what the agent wrote unseen and unapproved: it goes to the
  // node as it is, with the check that could not finish, and the check behavior runs the checks
  // alone again within the hour until they pass. The writing is not run again.
  if (checked.status === "could_not_finish") {
    await log(`the ${checked.check} check could not finish: ${checked.reason}`);
    if (o.dryRun) return { status: checked.signedOut ? "signed_out" : "dry_run", date };
    late = begin("hand over");
    if (late !== undefined) return fail(late);
    const r = await runNode(
      node,
      ["note", "--text", "-", "--checks", JSON.stringify(checked.runs), ...(await endsArg()), "--could-not-finish", checked.check, ...(checked.signedOut ? ["--signed-out"] : [])],
      w.note + "\n",
    );
    if (r.code !== 0) return fail(`digestif note exited ${r.code}: ${r.stderr.trim().slice(0, 200)}`);
    await finish("posted");
    await log("note handed over unchecked: its checks run again within the hour");
    return { status: "unchecked", date };
  }
  if (checked.status === "empty") {
    await log("the checks left nothing: no note is written");
    if (o.dryRun) return { status: "dry_run", date };
    // The day takes the Nothing to share path: no note, and no text of it anywhere.
    const err = await tick();
    if (err !== undefined) return fail(err);
    await resolve("write_version");
    await finish("quiet");
    return { status: "emptied", date };
  }
  if (o.dryRun) return { status: "dry_run", date, note: checked.text };

  // 4. Hand over the checked text and what each run removed, by part and cause, never by text.
  late = begin("hand over");
  if (late !== undefined) return fail(late);
  //    The agent approves; it never sends. It reads whether auto approval is saved only now, after
  //    writing, so a setting saved meanwhile applies; without it the note waits for the member.
  const approve = o.autoApprove ? await o.autoApprove().catch(() => false) : false;
  const r = await runNode(node, ["note", "--text", "-", "--checks", JSON.stringify(checked.runs), ...(await endsArg()), ...(approve ? ["--approve"] : [])], checked.text + "\n");
  if (r.code !== 0) return fail(`digestif note exited ${r.code}: ${r.stderr.trim().slice(0, 200)}`);
  await finish("posted");
  await log(approve ? "note handed over, auto approved" : "note handed over: waiting for the member");
  return { status: "posted", date };
}
