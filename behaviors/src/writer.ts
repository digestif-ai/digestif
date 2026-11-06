// The writer: step 2 of the nightly note (docs/design.md, The nightly note). The member's own
// coding agent, the one setup checked, run under their login with every tool disabled, drafts the
// note from the digest alone. The digest is the user message (data); the prompt file, the brief and
// the rules are the system prompt. Each agent is started with its own flags (harnessCommand): Claude
// Code and Codex keep the two apart, and a typed path, whose flags Digestif does not know, is given
// both as its one argument.

import { execFile, spawn } from "node:child_process";
import { readFileSync, rmSync } from "node:fs";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
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

/**
 * Which agent the harness is, so it gets its own flags: the kinds `digestif setup` records in
 * `behaviors/nightly/config.json` (node/invite/agents.ml).
 */
export type AgentKind = "claude_code" | "codex" | "other";

export const AGENT_KINDS: readonly AgentKind[] = ["claude_code", "codex", "other"];

/**
 * A harness with no recorded kind: Codex when its file name is `codex`, else Claude Code, the
 * writer's harness before setup recorded a kind. A typed path is "other" only when recorded so.
 */
export function agentOf(harness: string): AgentKind {
  return basename(harness) === "codex" ? "codex" : "claude_code";
}

export interface WriterOptions {
  /** The harness binary: `claude` by default (looked up on PATH). */
  harness?: string;
  /** The harness's kind; the one its file name names when absent (agentOf). */
  agent?: AgentKind;
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
  /** Learnings, which the note's writer reads after the rules. */
  learnings?: string;
  /**
   * Run with the tools the member's harness grants under its own settings, in their home directory,
   * rather than with none in an empty one: the Inbox agent's run (docs/design.md, The Inbox agent),
   * like the setup chat. Every other run has no tools.
   */
  tools?: boolean;
}

/** What a run came to. Only "note" carries a note. */
export type WriteResult =
  | { status: "note"; note: string }
  | { status: "empty" }
  | { status: "signed_out" }
  | { status: "out_of_budget" }
  | { status: "hung"; quietMs: number }
  | { status: "failed"; message: string };

/**
 * The problem kind a harness run that gave no answer is reported as (nightly.ts ProblemKind): no
 * login, the budget spent, or anything else the model did not answer.
 */
export type AgentProblem = "signed_out" | "out_of_budget" | "model_unavailable";

/** A run's problem kind, for a result that is not an answer. */
export function agentProblem(r: WriteResult): AgentProblem {
  return r.status === "signed_out" || r.status === "out_of_budget" ? r.status : "model_unavailable";
}

/** The harness's own failure to find a login, as Claude Code and Codex print it with a non-zero exit. */
const SIGNED_OUT = /not logged in|please run \/login|run \/login|claude auth login|oauth token has expired|invalid api key|codex login|not signed in/i;

export function isSignedOut(code: number | null, output: string): boolean {
  return code !== 0 && SIGNED_OUT.test(output);
}

/**
 * The harness stopped the run at --max-budget-usd: Claude Code ends it with a `result` event of
 * subtype `error_max_budget_usd` and a non-zero exit, whatever it had written by then.
 */
export function isOutOfBudget(result: StreamResult | undefined): boolean {
  return result?.subtype === "error_max_budget_usd";
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
export function harnessArgs(systemPrompt: string, maxBudgetUsd: number, tools = false): string[] {
  return [
    "-p",
    ...(tools ? [] : ["--tools", "", "--strict-mcp-config"]),
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

/**
 * Codex's switches for every tool it offers (`codex features list`): shell and exec, code mode,
 * sub-agents, goals, plugins and apps, the browser, the computer and images. Set as config values rather than
 * `--disable`, which refuses a name the installed Codex does not know; a value it does not know is
 * ignored, so a Codex older or newer than this list still runs.
 */
export const CODEX_TOOL_FEATURES = [
  "shell_tool",
  "unified_exec",
  "code_mode",
  "code_mode_host",
  "multi_agent",
  "multi_agent_v2",
  "sleep_tool",
  "goals",
  "plugins",
  "apps",
  "browser_use",
  "browser_use_external",
  "in_app_browser",
  "computer_use",
  "image_generation",
  "view_image",
];

/**
 * The model catalog fields that add tools no feature switch removes: code mode's `exec` and `wait`
 * (`tool_mode` `code_mode_only`, which nests `apply_patch` and the model's experimental tools), and
 * the sub-agent tools (`multi_agent_version`, which `features.multi_agent=false` does not override).
 * Each is set to the value that offers nothing.
 */
export const CODEX_CATALOG_NO_TOOLS: Readonly<Record<string, unknown>> = {
  tool_mode: "direct",
  experimental_supported_tools: [],
  apply_patch_tool_type: null,
  multi_agent_version: null,
};

/**
 * The installed Codex's model catalog (`codex debug models`) with CODEX_CATALOG_NO_TOOLS applied to
 * every model. Only a field the model already has is changed, so a Codex that renamed one runs with
 * that tool back rather than a field it does not know. Undefined when the output is not a catalog.
 */
export function codexCatalog(json: string): string | undefined {
  let d: unknown;
  try {
    d = JSON.parse(json);
  } catch {
    return undefined;
  }
  const models = typeof d === "object" && d !== null ? (d as { models?: unknown }).models : undefined;
  if (!Array.isArray(models)) return undefined;
  for (const m of models) {
    if (typeof m !== "object" || m === null) continue;
    for (const [k, v] of Object.entries(CODEX_CATALOG_NO_TOOLS)) if (k in m) (m as Record<string, unknown>)[k] = v;
  }
  return JSON.stringify(d);
}

/**
 * Codex's flags: one non-interactive run, saving no session, streaming JSON events, in a read-only
 * sandbox, with every tool feature off, multi-agent off (`agents.enabled`, which removes the
 * `collaboration` tools the model catalog's multi-agent version adds whatever `features.multi_agent`
 * says), no MCP server, no web search and no question to the user (`request_user_input`, which no
 * feature switch removes). With `catalog`, the path of a
 * codexCatalog file, the model offers no code mode and no sub-agents either, so the request carries
 * no tool at all. The system prompt is its developer instructions, a TOML string; the digest is the
 * prompt, read from stdin (`-`).
 */
export function codexArgs(systemPrompt: string, catalog?: string, tools = false): string[] {
  // With the harness's own tools: one non-interactive run saving no session, under the member's own
  // Codex configuration, its sandbox and approvals included.
  if (tools) return ["exec", "--skip-git-repo-check", "--ephemeral", "--json", "-c", `developer_instructions=${JSON.stringify(systemPrompt)}`, "-"];
  return [
    "exec",
    "--skip-git-repo-check",
    "--ephemeral",
    "--sandbox",
    "read-only",
    "--json",
    ...CODEX_TOOL_FEATURES.flatMap((f) => ["-c", `features.${f}=false`]),
    "-c",
    "agents.enabled=false",
    "-c",
    "mcp_servers={}",
    "-c",
    'web_search="disabled"',
    "-c",
    "tools.experimental_request_user_input={enabled=false}",
    // JSON's string escapes are TOML's basic-string escapes.
    ...(catalog === undefined ? [] : ["-c", `model_catalog_json=${JSON.stringify(catalog)}`]),
    "-c",
    `developer_instructions=${JSON.stringify(systemPrompt)}`,
    "-",
  ];
}

/**
 * Writes the no-tools catalog of the Codex at `harness` into `dir` and returns its path. Undefined
 * when that Codex prints no catalog (one older than `codex debug models`, or not Codex at all): the
 * run then goes ahead without it, and code mode and sub-agents stay offered but cannot run, since
 * their hosts are switched off.
 */
async function writeCodexCatalog(harness: string, dir: string): Promise<string | undefined> {
  const stdout = await new Promise<string | undefined>((resolve) => {
    execFile(harness, ["debug", "models"], { env: childEnv(), timeout: 30_000, maxBuffer: 64 * 1024 * 1024 }, (err, out) => resolve(err ? undefined : out));
  });
  const catalog = stdout === undefined ? undefined : codexCatalog(stdout);
  if (catalog === undefined) return undefined;
  const path = join(dir, "model-catalog.json");
  await writeFile(path, catalog);
  return path;
}

/** A typed path's one argument: the system prompt, then the data. */
export function otherPrompt(systemPrompt: string, input: string): string {
  return `${systemPrompt}\n\n---\n\n${input}`;
}

/** How one agent is started: its arguments and what it reads on stdin. */
export function harnessCommand(agent: AgentKind, systemPrompt: string, input: string, maxBudgetUsd: number, codexCatalogPath?: string, tools = false): { args: string[]; stdin: string } {
  switch (agent) {
    case "claude_code":
      return { args: harnessArgs(systemPrompt, maxBudgetUsd, tools), stdin: input };
    case "codex":
      return { args: codexArgs(systemPrompt, codexCatalogPath, tools), stdin: input };
    case "other":
      return { args: [otherPrompt(systemPrompt, input)], stdin: "" };
  }
}

/**
 * Codex's answer from its `--json` stream: the last `agent_message` item's text. A `turn.failed` or a
 * top-level `error` event is the run's failure; an `error` ITEM is a warning and is not.
 */
export function codexResult(stdout: string): StreamResult | undefined {
  let text: string | undefined;
  let failure: string | undefined;
  for (const line of stdout.split("\n")) {
    let e: unknown;
    try {
      e = JSON.parse(line);
    } catch {
      continue;
    }
    if (typeof e !== "object" || e === null) continue;
    const ev = e as { type?: unknown; item?: { type?: unknown; text?: unknown }; error?: { message?: unknown }; message?: unknown };
    if (ev.type === "item.completed" && ev.item?.type === "agent_message" && typeof ev.item.text === "string") text = ev.item.text;
    else if (ev.type === "turn.failed") failure = typeof ev.error?.message === "string" ? ev.error.message : "turn failed";
    else if (ev.type === "error") failure = typeof ev.message === "string" ? ev.message : "error";
  }
  if (failure !== undefined) return { isError: true, text: failure, subtype: "error" };
  return text === undefined ? undefined : { isError: false, text, subtype: "success" };
}

/** Claude Code's answer: the stream's last `result` event. */
function claudeResult(stdout: string): StreamResult | undefined {
  let r: StreamResult | undefined;
  for (const line of stdout.split("\n")) r = resultEvent(line) ?? r;
  return r;
}

/** What a run answered, read the way its agent writes it. A typed path's answer is its stdout. */
export function answerOf(agent: AgentKind, code: number | null, stdout: string): StreamResult | undefined {
  switch (agent) {
    case "claude_code":
      return claudeResult(stdout);
    case "codex":
      return codexResult(stdout);
    case "other":
      return { isError: code !== 0, text: stdout, subtype: code === 0 ? "success" : "error" };
  }
}

/** Variables the harness never sees. */
export const CHILD_ENV_REMOVED = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "DIGESTIF_SESSION"];

/** The harness's environment. No API key: the harness runs under the member's login. Nor the node's UI session cookie. */
function childEnv(): NodeJS.ProcessEnv {
  const env = { ...process.env };
  for (const k of CHILD_ENV_REMOVED) delete env[k];
  return env;
}

/** Harness process groups running now, with their working directories, so a SIGTERM can end them. */
const active = new Map<number, string>();
/** Codex catalog directories of runs in flight, removed with them. */
const catalogDirs = new Set<string>();

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
  for (const d of catalogDirs) rmSync(d, { recursive: true, force: true });
  catalogDirs.clear();
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
  stdout: string;
  stderr: string;
  hung: boolean;
  spawnError?: string;
}

function run(cmd: string, args: string[], input: string, cwd: string, quietMs: number, now: () => number): Promise<Ran> {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { cwd, env: childEnv(), detached: true, stdio: ["pipe", "pipe", "pipe"] });
    if (child.pid !== undefined) active.set(child.pid, cwd);
    let stdout = "";
    let stderr = "";
    let hung = false;
    let settled = false;
    const clock = new AwakeClock(now);
    let heard = 0;
    const done = (r: Omit<Ran, "stdout">) => {
      if (settled) return;
      settled = true;
      if (child.pid !== undefined) active.delete(child.pid);
      clearInterval(timer);
      resolve({ ...r, stdout });
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
      stdout += d;
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
  const system = buildSystemPrompt(template, options.brief ?? "", options.rules ?? "", brief ? "" : (options.learnings ?? ""));
  const input = `${brief ? "The person's card and sources" : "The day's digest"}, as data:\n\n${lines.join("\n")}\n`;
  return askHarness(system, input, options);
}

/** The options a harness run takes: the writer's, and each model check's. */
export type HarnessOptions = Pick<WriterOptions, "harness" | "agent" | "quietMs" | "now" | "maxBudgetUsd" | "tools">;

/**
 * One run of the harness, the system prompt and the user message given: the writer's and each
 * model check's (src/checks.ts) with no tools, in an empty directory; the Inbox agent's with the
 * harness's own (`tools`), in the member's home directory. The answer is the run's text, trimmed;
 * an empty one is "empty".
 */
export async function askHarness(system: string, input: string, options: HarnessOptions = {}): Promise<WriteResult> {
  const tools = options.tools === true;
  const empty = await mkdtemp(join(tmpdir(), "digestif-writer-"));
  const cwd = tools ? homedir() : empty;
  // The catalog sits beside the run's directory, never in it: the harness starts in an empty one.
  let catalogDir: string | undefined;
  try {
    const quietMs = options.quietMs ?? DEFAULT_QUIET_MS;
    const harness = options.harness ?? "claude";
    const agent = options.agent ?? agentOf(harness);
    if (agent === "codex" && !tools) catalogDirs.add((catalogDir = await mkdtemp(join(tmpdir(), "digestif-codex-catalog-"))));
    const catalog = catalogDir === undefined ? undefined : await writeCodexCatalog(harness, catalogDir);
    const cmd = harnessCommand(agent, system, input, options.maxBudgetUsd ?? DEFAULT_MAX_BUDGET_USD, catalog, tools);
    const r = await run(harness, cmd.args, cmd.stdin, cwd, quietMs, options.now ?? Date.now);
    if (r.hung) return { status: "hung", quietMs };
    if (r.spawnError !== undefined) return { status: "failed", message: `cannot run the harness: ${r.spawnError}` };
    const result = answerOf(agent, r.code, r.stdout);
    const said = result?.text ?? "";
    if (isSignedOut(r.code === 0 && result?.isError ? 1 : r.code, said + "\n" + r.stderr)) return { status: "signed_out" };
    if (isOutOfBudget(result)) return { status: "out_of_budget" };
    if (r.code !== 0 || result?.isError) {
      const why = (said.trim() || result?.subtype || r.stderr.trim()).slice(0, 300);
      return { status: "failed", message: `the harness exited ${r.code}: ${why}` };
    }
    const note = said.trim();
    return note === "" ? { status: "empty" } : { status: "note", note };
  } finally {
    await rm(empty, { recursive: true, force: true });
    if (catalogDir !== undefined) {
      catalogDirs.delete(catalogDir);
      await rm(catalogDir, { recursive: true, force: true });
    }
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

/** The node's local API, checked to be its loopback address, and the headers every request carries. */
export function nodeApi(access: NodeAccess | ApiAccess): { base: URL; headers: Record<string, string> } {
  const given = "url" in access;
  const base = new URL(given ? access.url : access.node);
  if (base.protocol !== "http:" || !LOOPBACK.has(base.hostname)) {
    throw new Error(`the node's API must be its loopback address (http://127.0.0.1:<port>), not ${base.origin}`);
  }
  return { base, headers: given ? access.headers : { cookie: `digestif_session=${access.session}`, "digestif-local": "1" } };
}

/**
 * Whether the member saved auto approval (GET /api/v0/settings/approval). The agent reads it only
 * after writing a note, and approves the note when it is saved. Anything but a clear yes, an
 * unreachable node included, is no: the note waits for the member.
 */
export async function fetchAutoApprove(access: NodeAccess | ApiAccess | null): Promise<boolean> {
  if (access === null) return false;
  const { base, headers } = nodeApi(access);
  try {
    const res = await fetch(new URL("/api/v0/settings/approval", base), { headers, signal: AbortSignal.timeout(5_000) });
    if (!res.ok) return false;
    return ((await res.json()) as { setting?: unknown }).setting === "auto_approve";
  } catch {
    return false;
  }
}
