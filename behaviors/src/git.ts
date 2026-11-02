// Commits from one repository's default branch, with their full messages, never a diff or a file
// name (DES-37265, The record and where each note starts). A repository is one remote; its clones
// are read together and every commit counted once.

import { execFile } from "node:child_process";

function run(args: string[]): Promise<{ code: number; stdout: string }> {
  return new Promise((resolve) => {
    execFile("git", args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 }, (error, stdout) => {
      if (error && typeof error.code !== "number") return resolve({ code: 1, stdout: "" });
      resolve({ code: error ? (error.code as number) : 0, stdout });
    });
  });
}

export interface Commit {
  sha: string;
  /** The committer time, epoch milliseconds. */
  at: number;
  /** The author's email, lowercased. */
  email: string;
  /** The whole message, subject and body. */
  message: string;
  /** More than one parent. */
  merge: boolean;
}

/**
 * The default branch: what the remote's HEAD names (`origin/HEAD`), else the checked-out branch.
 * Undefined for a directory that is not a repository or has no commit.
 */
export async function defaultRef(repo: string): Promise<string | undefined> {
  const remote = await run(["-C", repo, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"]);
  if (remote.code === 0 && remote.stdout.trim() !== "") return remote.stdout.trim();
  const head = await run(["-C", repo, "rev-parse", "--verify", "--quiet", "HEAD"]);
  return head.code === 0 ? "HEAD" : undefined;
}

async function isAncestor(repo: string, sha: string, ref: string): Promise<boolean> {
  return (await run(["-C", repo, "merge-base", "--is-ancestor", sha, ref])).code === 0;
}

const FIELD = "\x1f";
const RECORD = "\x1e";

function parse(stdout: string): Commit[] {
  return stdout
    .split(RECORD)
    .map((r) => r.replace(/^\n/, ""))
    .filter((r) => r !== "")
    .flatMap((r) => {
      const [sha, ct, email, parents, ...message] = r.split(FIELD);
      if (sha === undefined || ct === undefined || email === undefined || parents === undefined) return [];
      return [
        {
          sha,
          at: Number(ct) * 1000,
          email: email.trim().toLowerCase(),
          message: message.join(FIELD).trim(),
          merge: parents.trim().split(" ").filter((p) => p !== "").length > 1,
        },
      ];
    });
}

/**
 * The default branch's commits after a point, oldest first. With `sha` still on the branch, the
 * commits after it; a sha rebased away falls back to committer time after `since`, leaving out the
 * sha itself. Without either, every commit (the caller bounds it with `since`).
 */
export async function commitsAfter(repo: string, from: { since?: number; sha?: string }): Promise<Commit[]> {
  const ref = await defaultRef(repo);
  if (ref === undefined) return [];
  const bySha = from.sha !== undefined && (await isAncestor(repo, from.sha, ref));
  const range = bySha ? [ref, `^${from.sha}`] : [ref, ...(from.since === undefined ? [] : [`--since=@${Math.floor(from.since / 1000)}`])];
  const { code, stdout } = await run(["-C", repo, "log", "--reverse", `--format=%H${FIELD}%ct${FIELD}%ae${FIELD}%P${FIELD}%B${RECORD}`, ...range]);
  if (code !== 0) return [];
  // --since keeps a commit at the second of the point; it was read.
  return parse(stdout).filter((c) => c.sha !== from.sha && (bySha || from.since === undefined || c.at > from.since));
}

/** The commits of every clone of one repository, each once, oldest first. */
export async function repositoryCommits(paths: string[], from: { since?: number; sha?: string }): Promise<Commit[]> {
  const bySha = new Map<string, Commit>();
  for (const p of paths) for (const c of await commitsAfter(p, from)) if (!bySha.has(c.sha)) bySha.set(c.sha, c);
  return [...bySha.values()].sort((a, b) => a.at - b.at);
}

/**
 * Bookkeeping: read and counted, but noise to the writer (DES-37265). A merge with no message of
 * its own (git's generated "Merge branch ..." line and nothing else), and memory, plan and sync
 * commits, told by their subject.
 */
export function isBookkeeping(c: Pick<Commit, "message" | "merge">): boolean {
  const lines = c.message.split("\n").filter((l) => l.trim() !== "");
  const subject = lines[0]?.trim() ?? "";
  if (c.merge && lines.length <= 1 && /^Merge (branch|remote-tracking branch|pull request|tag|commit) /i.test(subject)) return true;
  if (c.merge && subject === "") return true;
  return /^(auto[- ]?)?sync(ed|ing)?\b/i.test(subject) || /^(update|add|save|sync)\s+(memory|memories|plans?)\b/i.test(subject) || /^(memory|memories|plans?)\s*[:-]/i.test(subject);
}

/** A message as one line, whitespace collapsed, cut at `max` characters. */
export function messageLine(message: string, max: number): string {
  const one = message.replace(/\s+/g, " ").trim();
  return one.length <= max ? one : `${one.slice(0, max - 1)}…`;
}
