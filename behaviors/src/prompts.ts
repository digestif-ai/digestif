// ISS-51009: the nightly note prompt and the suggestions to change it (docs/design.md, Suggesting a
// change to the note prompt; docs/behaviors.md, The note prompt). The node folds the circle's
// suggestions and their judges' picks; this module asks it which prompt writes tonight's note and
// which suggestion, if any, writes its second version, and opens the pull request an adopted
// suggestion its member wrote is owed.

import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { nodeApi, PROMPT_FILE, type ApiAccess, type NodeAccess } from "./writer.ts";

/** A prompt's id: sha256 of its text as written, `sha256:<hex>`, the id a note written with it carries. */
export function promptId(text: string): string {
  return `sha256:${createHash("sha256").update(text, "utf8").digest("hex")}`;
}

/** The release's own prompt, which stands until the circle adopts a suggestion. */
export async function releasePrompt(file = PROMPT_FILE): Promise<string> {
  return (await readFile(file, "utf8")).trim();
}

/** A suggestion as the node serves it (spec/digestif-node.json, suggestion): the fields read here. */
export interface Suggestion {
  hash: string;
  change: string;
  text: string;
  prompt_id: string;
  pull_request_owed?: boolean;
}

/** GET /api/v0/note_prompt: the circle's live prompt, and the suggestion this member judges now. */
export interface NotePrompt {
  /** Absent while the release's prompt stands. */
  text?: string;
  running?: Suggestion;
}

async function getJson(access: NodeAccess | ApiAccess, path: string): Promise<unknown> {
  const { base, headers } = nodeApi(access);
  const res = await fetch(new URL(`/api/v0/${path}`, base), { headers, signal: AbortSignal.timeout(5_000) });
  if (!res.ok) throw new Error(`${path}: HTTP ${res.status}`);
  return res.json();
}

/**
 * The node's note prompt. A node released before suggestions answers 404, which reads as the
 * release's prompt and nothing to judge.
 */
export async function fetchNotePrompt(access: NodeAccess | ApiAccess | null): Promise<NotePrompt> {
  if (access === null) return {};
  let body: unknown;
  try {
    body = await getJson(access, "note_prompt");
  } catch (e) {
    if (/HTTP 404/.test((e as Error).message)) return {};
    throw e;
  }
  const b = body as { text?: unknown; running?: unknown };
  const running = readSuggestion(b.running);
  return { ...(typeof b.text === "string" && b.text.trim() !== "" ? { text: b.text } : {}), ...(running === undefined ? {} : { running }) };
}

function readSuggestion(v: unknown): Suggestion | undefined {
  if (typeof v !== "object" || v === null) return undefined;
  const s = v as Record<string, unknown>;
  if (typeof s["hash"] !== "string" || typeof s["text"] !== "string" || typeof s["prompt_id"] !== "string") return undefined;
  return {
    hash: s["hash"],
    change: typeof s["change"] === "string" ? s["change"] : "",
    text: s["text"],
    prompt_id: s["prompt_id"],
    ...(s["pull_request_owed"] === true ? { pull_request_owed: true } : {}),
  };
}

/** What tonight's note is written with: the current prompt, and the suggested one when this member judges one. */
export interface Prompts {
  current: { id: string; text: string };
  suggested?: { suggestion: string; id: string; text: string };
}

/**
 * The prompts for tonight, from the node's answer and the release's file. A suggestion whose text is
 * the current prompt has nothing to compare, so the note is written once.
 */
export function promptsOf(np: NotePrompt, release: string): Prompts {
  const text = np.text ?? release;
  const current = { id: promptId(text), text };
  const s = np.running;
  if (s === undefined || s.prompt_id === current.id) return { current };
  return { current, suggested: { suggestion: s.hash, id: s.prompt_id, text: s.text } };
}

/** The suggestions this member wrote that are adopted and owe their pull request. */
export async function owedPullRequests(access: NodeAccess | ApiAccess | null): Promise<Suggestion[]> {
  if (access === null) return [];
  let list: unknown;
  try {
    list = await getJson(access, "suggestions?limit=200");
  } catch {
    return [];
  }
  if (!Array.isArray(list)) return [];
  const mine = list.filter((r) => typeof r === "object" && r !== null && (r as { status?: unknown }).status === "adopted");
  const out: Suggestion[] = [];
  for (const row of mine) {
    const full = readSuggestion(await getJson(access, `suggestions/${encodeURIComponent((row as { hash: string }).hash)}`).catch(() => undefined));
    if (full?.pull_request_owed === true) out.push(full);
  }
  return out;
}

/** Records the pull request opened for a suggestion (PUT /suggestions/:hash/pull_request). */
export async function recordPullRequest(access: NodeAccess | ApiAccess, hash: string, url: string): Promise<void> {
  const { base, headers } = nodeApi(access);
  const res = await fetch(new URL(`/api/v0/suggestions/${encodeURIComponent(hash)}/pull_request`, base), {
    method: "PUT",
    headers: { ...headers, "content-type": "application/json" },
    body: JSON.stringify({ url }),
    signal: AbortSignal.timeout(5_000),
  });
  if (!res.ok) throw new Error(`recording the pull request: HTTP ${res.status}`);
}

/** The repository whose release ships the prompt every new member starts with. */
export const DEFAULT_REPOSITORY = "digestif-ai/digestif";
export const PROMPT_PATH = "behaviors/prompts/nightly-note.md";

export interface Ran {
  code: number | null;
  stdout: string;
  stderr: string;
}

export type Runner = (cmd: string, args: string[], cwd?: string) => Promise<Ran>;

/** Runs a program with no stdin. */
export const run: Runner = (cmd, args, cwd) =>
  new Promise((resolve) => {
    const child = spawn(cmd, args, { cwd, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8").on("data", (d: string) => (stdout += d));
    child.stderr.setEncoding("utf8").on("data", (d: string) => (stderr += d));
    child.on("error", (e) => resolve({ code: null, stdout, stderr: stderr + e.message }));
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });

/**
 * Opens the pull request proposing an adopted prompt as the release's default: a fresh clone of the
 * repository through the member's own `gh`, a branch named for the suggestion, the file replaced, a
 * push, and `gh pr create`. Answers the pull request's url. It needs `gh` signed in as someone who
 * may push a branch there; anything else is an error the caller reports as a problem, and the
 * next night tries again.
 */
export async function openPullRequest(s: Suggestion, o: { repository?: string; runner?: Runner } = {}): Promise<string> {
  const repo = o.repository ?? DEFAULT_REPOSITORY;
  const sh = o.runner ?? run;
  const dir = await mkdtemp(join(tmpdir(), "digestif-prompt-"));
  const must = async (cmd: string, args: string[], cwd?: string): Promise<string> => {
    const r = await sh(cmd, args, cwd);
    if (r.code !== 0) throw new Error(`${cmd} ${args[0] ?? ""} exited ${r.code}: ${r.stderr.trim().slice(0, 200)}`);
    return r.stdout;
  };
  try {
    const clone = join(dir, "repo");
    await must("gh", ["repo", "clone", repo, clone, "--", "--depth", "1"]);
    const branch = `note-prompt-${s.hash.replace(/^sha256:/, "").slice(0, 12)}`;
    await must("git", ["checkout", "-b", branch], clone);
    await writeFile(join(clone, PROMPT_PATH), s.text.trimEnd() + "\n");
    await must("git", ["add", PROMPT_PATH], clone);
    const title = `Adopt the circle's nightly note prompt: ${s.change}`.slice(0, 120);
    await must("git", ["commit", "-m", title], clone);
    await must("git", ["push", "--set-upstream", "origin", branch], clone);
    const body = [
      `The circle adopted this nightly note prompt: every judge of suggestion ${s.hash} picked the version it wrote.`,
      "",
      `What it changes: ${s.change}`,
      "",
      "Merging it makes it the prompt the next release gives every new member.",
    ].join("\n");
    const out = await must("gh", ["pr", "create", "--repo", repo, "--head", branch, "--base", "main", "--title", title, "--body", body], clone);
    const url = out
      .trim()
      .split("\n")
      .reverse()
      .find((l) => /^https:\/\//.test(l.trim()));
    if (url === undefined) throw new Error("gh pr create printed no url");
    return url.trim();
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}
