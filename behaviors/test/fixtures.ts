// Fixtures built in a temp directory by the tests: a fake ~/.claude/projects tree and a fake git
// repository. Every value is made up; no transcript or repository of a real member is read.
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

export type Entry = Record<string, unknown>;

export function user(text: string | unknown[], at: string, extra: Entry = {}): Entry {
  return { type: "user", message: { role: "user", content: text }, timestamp: at, uuid: `u-${at}`, ...extra };
}

export function assistant(text: string, at: string): Entry {
  return { type: "assistant", message: { role: "assistant", content: [{ type: "text", text }] }, timestamp: at };
}

export function jsonl(entries: Entry[]): string {
  return entries.map((e) => JSON.stringify(e)).join("\n") + "\n";
}

export interface Fixture {
  home: string;
  projects: string;
  repo: string;
  remove(): void;
}

/** A home with two sessions of the day under ~/.claude/projects and one repository under ~/code. */
export function build(): Fixture {
  const home = mkdtempSync(join(tmpdir(), "digestif-behaviors-"));
  const projects = join(home, ".claude", "projects");

  // Session alpha: begun the day before (its title), continued today with prompts of every shape
  // Claude Code records as "user": slash commands, tool results, skill injections, a sidechain,
  // a compaction summary, an SDK-sent prompt, a pasted image, a repeated prompt and an over-long one.
  const alpha = join(projects, "-Users-member-code-alpha");
  mkdirSync(alpha, { recursive: true });
  const long = "Please rewrite the fetcher so that it " + "retries politely ".repeat(20);
  writeFileSync(
    join(alpha, "aaaa0000-0000-4000-8000-000000000001.jsonl"),
    jsonl([
      { type: "file-history-snapshot", messageId: "x" },
      user("Set up the alpha repo with a CI pipeline", "2026-10-27T21:00:00.000Z"),
      assistant("Done: a workflow that runs the tests.", "2026-10-27T21:01:00.000Z"),
      user("<command-name>/model</command-name>\n<command-message>model</command-message>", "2026-10-28T14:00:00.000Z"),
      user("<local-command-stdout>Set model to opus</local-command-stdout>", "2026-10-28T14:00:01.000Z"),
      user("Add a retry to the fetcher\nKeep the second line out of the digest.", "2026-10-28T14:05:00.000Z"),
      user(
        [{ type: "tool_result", tool_use_id: "toolu_1", content: "token=sk-not-a-real-key-at-all-0000000000" }],
        "2026-10-28T14:06:00.000Z",
      ),
      user([{ type: "text", text: "Base directory for this skill: /skills/x" }], "2026-10-28T14:07:00.000Z", { isMeta: true }),
      user("A subagent's prompt that is not the member's", "2026-10-28T14:08:00.000Z", { isSidechain: true }),
      user(
        [
          { type: "text", text: "[Image #1] the fonts are overlapping" },
          { type: "image", source: { type: "base64", media_type: "image/png", data: "AAAA" } },
        ],
        "2026-10-28T14:09:00.000Z",
      ),
      user([{ type: "text", text: "[Request interrupted by user for tool use]" }], "2026-10-28T14:10:00.000Z"),
      user("This session is being continued from a previous conversation. Summary: token=sk-not-real-1111", "2026-10-28T14:10:30.000Z", {
        isCompactSummary: true,
        isVisibleInTranscriptOnly: true,
      }),
      user("A build prompt the factory daemon sent through the SDK", "2026-10-28T14:10:40.000Z", { promptSource: "sdk", turnOrigin: "sdk" }),
      user("Add a retry to the fetcher", "2026-10-28T14:11:00.000Z"),
      user(long, "2026-10-28T14:12:00.000Z"),
      user("Tomorrow's prompt, outside the day", "2026-10-29T00:00:00.000Z"),
    ]),
  );

  // Session beta: begun today, so its title is also today's first prompt. A subagent transcript
  // sits under a directory named after the session and is not the member's.
  const beta = join(projects, "-Users-member-code-beta");
  const betaId = "bbbb0000-0000-4000-8000-000000000002";
  mkdirSync(join(beta, betaId), { recursive: true });
  writeFileSync(
    join(beta, `${betaId}.jsonl`),
    jsonl([
      user("Why does the beta build fail on Linux?", "2026-10-28T08:00:00.000Z"),
      assistant("The linker flags differ.", "2026-10-28T08:01:00.000Z"),
      user("Try the Linux build with the older toolchain", "2026-10-28T09:00:00.000Z"),
    ]),
  );
  writeFileSync(
    join(beta, betaId, "cccc0000-0000-4000-8000-000000000003.jsonl"),
    jsonl([user("Subagent: list the linker flags", "2026-10-28T08:30:00.000Z")]),
  );

  // Session gamma: nothing today. Session delta: a prompt today, but the file was last written
  // before the day began, which cannot happen for a real transcript; it is skipped unread.
  const gamma = join(projects, "-Users-member-code-gamma");
  mkdirSync(gamma, { recursive: true });
  writeFileSync(join(gamma, "dddd0000-0000-4000-8000-000000000004.jsonl"), jsonl([user("Old work", "2026-10-26T10:00:00.000Z")]));
  const stale = join(gamma, "eeee0000-0000-4000-8000-000000000005.jsonl");
  writeFileSync(stale, jsonl([user("A prompt the file's mtime denies", "2026-10-28T10:00:00.000Z")]));
  utimesSync(stale, new Date("2026-10-20T00:00:00Z"), new Date("2026-10-20T00:00:00Z"));
  writeFileSync(join(projects, "README.txt"), "not a project directory\n");

  // The repository: two commits today, one yesterday, one tomorrow, and a merge today.
  const repo = join(home, "code", "fetcher");
  mkdirSync(repo, { recursive: true });
  const git = (args: string[], date?: string) =>
    execFileSync("git", args, {
      cwd: repo,
      stdio: ["ignore", "pipe", "pipe"],
      env: {
        ...process.env,
        GIT_AUTHOR_NAME: "Member",
        GIT_AUTHOR_EMAIL: "member@example.com",
        GIT_COMMITTER_NAME: "Member",
        GIT_COMMITTER_EMAIL: "member@example.com",
        ...(date ? { GIT_AUTHOR_DATE: date, GIT_COMMITTER_DATE: date } : {}),
        GIT_CONFIG_GLOBAL: "/dev/null",
        GIT_CONFIG_SYSTEM: "/dev/null",
      },
    });
  let n = 0;
  const commit = (subject: string, date: string) => {
    writeFileSync(join(repo, `note-${++n}.txt`), `${subject}\n`);
    git(["add", "."]);
    git(["commit", "-q", "-m", `${subject}\n\nA body the digest never carries: secret=hunter2-not-real.`], date);
  };
  git(["init", "-q", "-b", "main"]);
  commit("Yesterday's commit", "2026-10-27T23:59:59Z");
  commit("Start the fetcher", "2026-10-28T00:00:00Z");
  git(["checkout", "-q", "-b", "retry"]);
  commit("Add a retry to the fetcher", "2026-10-28T12:00:00Z");
  git(["checkout", "-q", "main"]);
  commit("Document the fetcher", "2026-10-28T13:00:00Z");
  git(["merge", "-q", "--no-ff", "-m", "Merge branch 'retry'", "retry"], "2026-10-28T14:00:00Z");
  commit("Tomorrow's commit", "2026-10-29T00:00:00Z");

  return { home, projects, repo, remove: () => rmSync(home, { recursive: true, force: true }) };
}
