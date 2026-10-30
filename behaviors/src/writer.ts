// The writer: step 2 of the nightly note (docs/design.md, The nightly note). The member's own
// Claude Code, run in print mode under their login with every tool disabled, drafts the note from
// the digest alone. The digest is the user message (data); the prompt file, the brief and the
// rules are the system prompt.

import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const DEFAULT_TIMEOUT_MS = 5 * 60_000;
/** Dollars per run, passed as --max-budget-usd. A note from at most 30 lines is a few cents. */
export const DEFAULT_MAX_BUDGET_USD = 0.5;

/** docs/design.md, Guarding what goes out: the conservative set. */
export const DEFAULT_RULES = [
  "- Name no customer, no employer-confidential project, no colleague and no third party.",
  "- Quote no code and no log.",
].join("\n");

export const PROMPT_FILE = join(dirname(fileURLToPath(import.meta.url)), "..", "prompts", "nightly-note.md");

export interface WriterOptions {
  /** The harness binary: `claude` by default (looked up on PATH). */
  harness?: string;
  /** Milliseconds before the harness is killed. */
  timeoutMs?: number;
  maxBudgetUsd?: number;
  /** The prompt file's text; read from PROMPT_FILE when absent. */
  prompt?: string;
  brief?: string;
  rules?: string;
}

/** What a run came to. Only "note" carries a note. */
export type WriteResult =
  | { status: "note"; note: string }
  | { status: "empty" }
  | { status: "signed_out" }
  | { status: "timeout" }
  | { status: "failed"; message: string };

/** The harness's own failure to find a login, as Claude Code prints it with a non-zero exit. */
const SIGNED_OUT = /not logged in|please run \/login|run \/login|claude auth login|oauth token has expired|invalid api key/i;

export function isSignedOut(code: number | null, output: string): boolean {
  return code !== 0 && SIGNED_OUT.test(output);
}

/** The system prompt: the prompt file with the brief and rules filled in. */
export function buildSystemPrompt(template: string, brief: string, rules: string): string {
  const fill = (text: string) => (text.trim() === "" ? "(none)" : text.trim());
  const values: Record<string, string> = { brief: fill(brief), default_rules: DEFAULT_RULES, rules: fill(rules) };
  return template.replace(/\{\{(brief|default_rules|rules)\}\}/g, (_, k: string) => values[k] ?? "");
}

/**
 * The harness's flags: print mode, no tools, no saved session, a budget, the system prompt.
 * `--tools ""` empties only the built-in set; `--strict-mcp-config` with no `--mcp-config` loads no
 * MCP server, so the member's configured servers add no tools either.
 */
export function harnessArgs(systemPrompt: string, maxBudgetUsd: number): string[] {
  return [
    "-p",
    "--tools",
    "",
    "--strict-mcp-config",
    "--no-session-persistence",
    "--output-format",
    "text",
    "--max-budget-usd",
    String(maxBudgetUsd),
    "--system-prompt",
    systemPrompt,
  ];
}

/** Variables the harness never sees. */
export const CHILD_ENV_REMOVED = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "DIGESTIF_SESSION"];

interface Ran {
  code: number | null;
  stdout: string;
  stderr: string;
  timedOut: boolean;
  spawnError?: string;
}

function run(cmd: string, args: string[], input: string, cwd: string, timeoutMs: number): Promise<Ran> {
  return new Promise((resolve) => {
    // No API key: the harness runs under the member's login. Nor the node's UI session cookie.
    const env = { ...process.env };
    for (const k of CHILD_ENV_REMOVED) delete env[k];
    const child = spawn(cmd, args, { cwd, env, detached: true, stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    let settled = false;
    const done = (r: Ran) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(r);
    };
    const killGroup = () => {
      try {
        if (child.pid !== undefined) process.kill(-child.pid, "SIGKILL");
      } catch {
        child.kill("SIGKILL");
      }
    };
    const timer = setTimeout(() => {
      timedOut = true;
      killGroup();
    }, timeoutMs);
    child.stdout.setEncoding("utf8").on("data", (d: string) => (stdout += d));
    child.stderr.setEncoding("utf8").on("data", (d: string) => (stderr += d));
    child.on("error", (e) => done({ code: null, stdout, stderr, timedOut, spawnError: e.message }));
    child.on("close", (code) => done({ code, stdout, stderr, timedOut }));
    child.stdin.on("error", () => {});
    child.stdin.end(input);
  });
}

/** Drafts the note. The harness runs in an empty temporary directory, so there is nothing to read. */
export async function writeNote(lines: string[], options: WriterOptions = {}): Promise<WriteResult> {
  const template = options.prompt ?? (await readFile(PROMPT_FILE, "utf8"));
  const system = buildSystemPrompt(template, options.brief ?? "", options.rules ?? "");
  const input = `The day's digest, as data:\n\n${lines.join("\n")}\n`;
  const cwd = await mkdtemp(join(tmpdir(), "digestif-writer-"));
  try {
    const r = await run(
      options.harness ?? "claude",
      harnessArgs(system, options.maxBudgetUsd ?? DEFAULT_MAX_BUDGET_USD),
      input,
      cwd,
      options.timeoutMs ?? DEFAULT_TIMEOUT_MS,
    );
    if (r.timedOut) return { status: "timeout" };
    if (r.spawnError !== undefined) return { status: "failed", message: `cannot run the harness: ${r.spawnError}` };
    if (isSignedOut(r.code, r.stdout + "\n" + r.stderr)) return { status: "signed_out" };
    if (r.code !== 0) return { status: "failed", message: `the harness exited ${r.code}: ${r.stderr.trim().slice(0, 300)}` };
    const note = r.stdout.trim();
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

const LOOPBACK = new Set(["127.0.0.1", "localhost", "[::1]"]);

/**
 * The brief and the rules text from the node's local API (GET /api/v0/brief, GET /api/v0/rules,
 * spec/digestif-node.json). The node binds 127.0.0.1 only, so any other host is refused before the
 * session cookie is sent anywhere.
 */
export async function fetchContext(access: NodeAccess): Promise<{ brief: string; rules: string }> {
  const base = new URL(access.node);
  if (base.protocol !== "http:" || !LOOPBACK.has(base.hostname)) {
    throw new Error(`DIGESTIF_NODE must be the node's loopback address (http://127.0.0.1:<port>), not ${base.origin}`);
  }
  const get = async (path: string): Promise<string> => {
    const res = await fetch(new URL(`/api/v0/${path}`, base), {
      headers: { cookie: `digestif_session=${access.session}`, "digestif-local": "1" },
      signal: AbortSignal.timeout(5_000),
    });
    if (!res.ok) throw new Error(`${path}: HTTP ${res.status}`);
    const body: unknown = await res.json();
    const text = (body as { text?: unknown }).text;
    return typeof text === "string" ? text : "";
  };
  return { brief: await get("brief"), rules: await get("rules") };
}
