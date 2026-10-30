// Commit subjects of the day from one repository: `git log` with a format of subjects only, never
// a diff, a body or a file name. Mirrors git_subjects in node/web/sources.ml.

import { execFile } from "node:child_process";
import type { Day } from "./day.ts";

/** node/web/sources.ml, git_subjects: `-n 50`, the most a repository contributes per day. */
export const MAX_COMMITS_PER_REPO = 50;

function run(args: string[]): Promise<{ code: number; stdout: string }> {
  return new Promise((resolve) => {
    execFile("git", args, { encoding: "utf8", maxBuffer: 16 * 1024 * 1024 }, (error, stdout) => {
      if (error && typeof error.code !== "number") return resolve({ code: 1, stdout: "" });
      resolve({ code: error ? (error.code as number) : 0, stdout });
    });
  });
}

/**
 * The subjects of the day's commits, newest first, merges left out. A directory that is not a
 * repository, or a git that fails, contributes nothing, as in the node.
 */
export async function commitSubjects(repo: string, day: Day): Promise<string[]> {
  const seconds = (ms: number) => Math.floor(ms / 1000);
  const { code, stdout } = await run([
    "-C",
    repo,
    "log",
    "--no-merges",
    `--since=@${seconds(day.start)}`,
    `--until=@${seconds(day.end) - 1}`,
    "--format=%s",
    "-n",
    String(MAX_COMMITS_PER_REPO),
  ]);
  if (code !== 0) return [];
  return stdout
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l !== "");
}
