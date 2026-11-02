// The writer: step 2 of the nightly note (docs/design.md, The nightly note). The member's own
// Claude Code, run in print mode under their login with every tool disabled, drafts the note from
// the digest alone. The digest is the user message (data); the prompt file, the brief and the
// rules are the system prompt.

import { spawn } from "node:child_process";
import { readFileSync, rmSync } from "node:fs";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { AwakeClock, TICK_MS } from "./awake.ts";
import { readDenyList, type DenyEntry } from "./deny.ts";

/**
 * A harness that writes nothing for this long, on a clock that stops while the machine sleeps, is
 * hung and is killed. There is no limit on a run that keeps writing: the budget bounds its cost.
 * The harness streams every event and token (`--output-format stream-json`), so a working run is
 * never this quiet.
 */
export const DEFAULT_QUIET_MS = 5 * 60_000;
/** Dollars per run, passed as --max-budget-usd. A full day's digest is at most MAX_DIGEST_CHARS. */
export const DEFAULT_MAX_BUDGET_USD = 2;

/** docs/design.md, Guarding what goes out: the conservative set. */
export const DEFAULT_RULES = [
  "- Name no customer, no employer-confidential project, no colleague and no third party.",
  "- Quote no code and no log.",
].join("\n");

const prompts = join(dirname(fileURLToPath(import.meta.url)), "..", "prompts");
export const PROMPTS_DIR = prompts;
export const PROMPT_FILE = join(prompts, "nightly-note.md");
/** The prompt for a first brief the member edits (DIGESTIF_WRITER_TASK=brief, docs/behaviors.md). */
export const BRIEF_PROMPT_FILE = join(prompts, "brief.md");

/** What the writer drafts: the nightly note, or a first brief from the card and the sources. */
export type WriterTask = "note" | "brief";

export interface WriterOptions {
  /** The harness binary: `claude` by default (looked up on PATH). */
  harness?: string;
  /** Awake milliseconds with no output before the harness is killed as hung. */
  quietMs?: number;
  /** The wall clock the awake clock reads; tests move it to stand in for a sleep. */
  now?: () => number;
  maxBudgetUsd?: number;
  /** The prompt file's text; read from the task's file (PROMPT_FILE, BRIEF_PROMPT_FILE) when absent. */
  prompt?: string;
  /** "note" when absent. */
  task?: WriterTask;
  brief?: string;
  rules?: string;
}

/** What a run came to. Only "note" carries a note. */
export type WriteResult =
  | { status: "note"; note: string }
  | { status: "empty" }
  | { status: "signed_out" }
  | { status: "hung"; quietMs: number }
  | { status: "failed"; message: string };

/** The harness's own failure to find a login, as Claude Code prints it with a non-zero exit. */
const SIGNED_OUT = /not logged in|please run \/login|run \/login|claude auth login|oauth token has expired|invalid api key/i;

export function isSignedOut(code: number | null, output: string): boolean {
  return code !== 0 && SIGNED_OUT.test(output);
}

/**
 * The always-on rules (docs/design.md, Guarding what goes out): one text, prompts/always-on.md,
 * that every prompt writing or acting for a member includes as {{always_on_rules}} and the Rules
 * page shows as it stands. No setting, rule or input turns it off, and no prompt carries a copy.
 */
export const ALWAYS_ON_FILE = join(prompts, "always-on.md");
export const ALWAYS_ON_RULES = readFileSync(ALWAYS_ON_FILE, "utf8").trim();
export const ALWAYS_ON_PLACEHOLDER = "{{always_on_rules}}";

/**
 * The system prompt: the prompt file with the always-on rules, the brief, the rules and Learnings
 * filled in.
 * A template that does not include the always-on rules is refused rather than run without them.
 */
export function buildSystemPrompt(template: string, brief: string, rules: string, learnings = ""): string {
  if (!template.includes(ALWAYS_ON_PLACEHOLDER)) {
    throw new Error(`the prompt does not include ${ALWAYS_ON_PLACEHOLDER}; every prompt that writes or acts for a member does`);
  }
  const fill = (text: string) => (text.trim() === "" ? "(none)" : text.trim());
  const values: Record<string, string> = { always_on_rules: ALWAYS_ON_RULES, brief: fill(brief), default_rules: DEFAULT_RULES, rules: fill(rules), learnings: fill(learnings) };
  return template.replace(/\{\{(always_on_rules|brief|default_rules|rules|learnings)\}\}/g, (_, k: string) => values[k] ?? "");
}

/**
 * The harness's flags: print mode, no tools, no saved session, a budget, the system prompt.
 * `--tools ""` empties only the built-in set; `--strict-mcp-config` with no `--mcp-config` loads no
 * MCP server, so the member's configured servers add no tools either. The output is streamed, one
 * JSON event a line with the partial messages, so silence means a hang; the answer is the last
 * `result` event's `result`.
 */
export function harnessArgs(systemPrompt: string, maxBudgetUsd: number): string[] {
  return [
    "-p",
    "--tools",
    "",
    "--strict-mcp-config",
    "--no-session-persistence",
    "--output-format",
    "stream-json",
    "--verbose",
    "--include-partial-messages",
    "--max-budget-usd",
    String(maxBudgetUsd),
    "--system-prompt",
    systemPrompt,
  ];
}

/** Variables the harness never sees. */
export const CHILD_ENV_REMOVED = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "DIGESTIF_SESSION"];

/** Harness process groups running now, with their working directories, so a SIGTERM can end them. */
const active = new Map<number, string>();

/**
 * Kills every running harness's whole process group (it was spawned detached, so the group is its
 * own) and removes its working directory. Synchronous: it is called from a signal handler that exits
 * right after. Returns how many groups were signalled.
 */
export function killHarnesses(): number {
  let n = 0;
  for (const [pid, cwd] of active) {
    try {
      process.kill(-pid, "SIGKILL");
      n++;
    } catch {
      /* already gone */
    }
    rmSync(cwd, { recursive: true, force: true });
  }
  active.clear();
  return n;
}

/** The stream's last `result` event: the answer, and whether the harness called it an error. */
export interface StreamResult {
  isError: boolean;
  text: string;
  subtype: string;
}

/** Reads one line of the harness's stream; anything but a `result` event is progress. */
export function resultEvent(line: string): StreamResult | undefined {
  let e: unknown;
  try {
    e = JSON.parse(line);
  } catch {
    return undefined;
  }
  if (typeof e !== "object" || e === null || (e as { type?: unknown }).type !== "result") return undefined;
  const r = e as { is_error?: unknown; result?: unknown; subtype?: unknown };
  return { isError: r.is_error === true, text: typeof r.result === "string" ? r.result : "", subtype: typeof r.subtype === "string" ? r.subtype : "" };
}

interface Ran {
  code: number | null;
  result: StreamResult | undefined;
  stderr: string;
  hung: boolean;
  spawnError?: string;
}

function run(cmd: string, args: string[], input: string, cwd: string, quietMs: number, now: () => number): Promise<Ran> {
  return new Promise((resolve) => {
    // No API key: the harness runs under the member's login. Nor the node's UI session cookie.
    const env = { ...process.env };
    for (const k of CHILD_ENV_REMOVED) delete env[k];
    const child = spawn(cmd, args, { cwd, env, detached: true, stdio: ["pipe", "pipe", "pipe"] });
    if (child.pid !== undefined) active.set(child.pid, cwd);
    let pending = "";
    let result: StreamResult | undefined;
    let stderr = "";
    let hung = false;
    let settled = false;
    const clock = new AwakeClock(now);
    let heard = 0;
    const done = (r: Omit<Ran, "result">) => {
      if (settled) return;
      settled = true;
      if (child.pid !== undefined) active.delete(child.pid);
      clearInterval(timer);
      if (pending !== "") result = resultEvent(pending) ?? result;
      resolve({ ...r, result });
    };
    const killGroup = () => {
      try {
        if (child.pid !== undefined) process.kill(-child.pid, "SIGKILL");
      } catch {
        child.kill("SIGKILL");
      }
    };
    // Silence is measured on the awake clock, read every tick so a sleep shows as one gap.
    const timer = setInterval(() => {
      if (!hung && clock.read() - heard >= quietMs) {
        hung = true;
        killGroup();
      }
    }, Math.min(TICK_MS, quietMs));
    const hear = () => (heard = clock.read());
    child.stdout.setEncoding("utf8").on("data", (d: string) => {
      hear();
      const lines = (pending + d).split("\n");
      pending = lines.pop() ?? "";
      for (const l of lines) result = resultEvent(l) ?? result;
    });
    child.stderr.setEncoding("utf8").on("data", (d: string) => {
      hear();
      stderr += d;
    });
    child.on("error", (e) => done({ code: null, stderr, hung, spawnError: e.message }));
    child.on("close", (code) => done({ code, stderr, hung }));
    child.stdin.on("error", () => {});
    child.stdin.end(input);
  });
}

/** Drafts the note. The harness runs in an empty temporary directory, so there is nothing to read. */
export async function writeNote(lines: string[], options: WriterOptions = {}): Promise<WriteResult> {
  const brief = options.task === "brief";
  const template = options.prompt ?? (await readFile(brief ? BRIEF_PROMPT_FILE : PROMPT_FILE, "utf8"));
  const system = buildSystemPrompt(template, options.brief ?? "", options.rules ?? "");
  const input = `${brief ? "The person's card and sources" : "The day's digest"}, as data:\n\n${lines.join("\n")}\n`;
  return askHarness(system, input, options);
}

/**
 * One run of the harness in print mode with no tools, the system prompt and the user message
 * given: the writer's, and each model check's (src/checks.ts). The answer is the
 * run's text, trimmed; an empty one is "empty".
 */
export async function askHarness(system: string, input: string, options: Pick<WriterOptions, "harness" | "quietMs" | "now" | "maxBudgetUsd"> = {}): Promise<WriteResult> {
  const cwd = await mkdtemp(join(tmpdir(), "digestif-writer-"));
  try {
    const quietMs = options.quietMs ?? DEFAULT_QUIET_MS;
    const r = await run(
      options.harness ?? "claude",
      harnessArgs(system, options.maxBudgetUsd ?? DEFAULT_MAX_BUDGET_USD),
      input,
      cwd,
      quietMs,
      options.now ?? Date.now,
    );
    if (r.hung) return { status: "hung", quietMs };
    if (r.spawnError !== undefined) return { status: "failed", message: `cannot run the harness: ${r.spawnError}` };
    const said = r.result?.text ?? "";
    if (isSignedOut(r.code === 0 && r.result?.isError ? 1 : r.code, said + "\n" + r.stderr)) return { status: "signed_out" };
    if (r.code !== 0 || r.result?.isError) {
      const why = (said.trim() || r.result?.subtype || r.stderr.trim()).slice(0, 300);
      return { status: "failed", message: `the harness exited ${r.code}: ${why}` };
    }
    const note = said.trim();
    return note === "" ? { status: "empty" } : { status: "note", note };
  } finally {
    await rm(cwd, { recursive: true, force: true });
  }
}

export interface NodeAccess {
  /** The node's local address, e.g. http://127.0.0.1:7420 (DIGESTIF_NODE). Loopback only. */
  node: string;
  /** The UI session cookie value (DIGESTIF_SESSION). */
  session: string;
}

/** The hook handoff's `api` (docs/behaviors.md): the URL and the exact headers every request carries. */
export interface ApiAccess {
  url: string;
  headers: Record<string, string>;
}

const LOOPBACK = new Set(["127.0.0.1", "localhost", "[::1]"]);

/** What the node serves a run: the brief, Rules, Learnings and the deny list. */
export interface NodeContext {
  brief: string;
  rules: string;
  learnings: string;
  deny: DenyEntry[];
}

/**
 * The brief, the rules text, Learnings and the deny list from the node's local API (GET
 * /api/v0/brief, /rules, /learnings and /rules/deny, spec/digestif-node.json). The node binds
 * 127.0.0.1 only, so any other host is refused before the headers are sent anywhere. Either the
 * interim `{ node, session }` or the handoff's `{ url, headers }`, whose headers go as given; `null`
 * (the node serves no web UI) is all empty. Learnings the node does not serve yet are empty.
 */
export async function fetchContext(access: NodeAccess | ApiAccess | null): Promise<NodeContext> {
  if (access === null) return { brief: "", rules: "", learnings: "", deny: [] };
  const given = "url" in access;
  const base = new URL(given ? access.url : access.node);
  if (base.protocol !== "http:" || !LOOPBACK.has(base.hostname)) {
    throw new Error(`the node's API must be its loopback address (http://127.0.0.1:<port>), not ${base.origin}`);
  }
  const headers = given ? access.headers : { cookie: `digestif_session=${access.session}`, "digestif-local": "1" };
  const json = async (path: string): Promise<unknown> => {
    const res = await fetch(new URL(`/api/v0/${path}`, base), { headers, signal: AbortSignal.timeout(5_000) });
    if (!res.ok) throw new Error(`${path}: HTTP ${res.status}`);
    return res.json();
  };
  const text = (body: unknown) => {
    const t = (body as { text?: unknown }).text;
    return typeof t === "string" ? t : "";
  };
  return {
    brief: text(await json("brief")),
    rules: text(await json("rules")),
    learnings: await json("learnings").then(text, () => ""),
    deny: readDenyList(await json("rules/deny")),
  };
}
