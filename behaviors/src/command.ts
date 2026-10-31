// A command source's lines (docs/behaviors.md, Command sources): the member's program, run as its
// paths with --since UNIX_SECONDS appended, one item per line of stdout. Mirrors command_lines in
// node/web/sources.ml: the same timeout, lines per source and line length.

import { execFile } from "node:child_process";

/** node/web/sources.ml, command_timeout, in milliseconds. */
export const COMMAND_TIMEOUT_MS = 30_000;
/** node/web/sources.ml, max_command_lines. */
export const MAX_COMMAND_LINES = 30;
/** node/web/sources.ml, max_line_chars. */
export const MAX_LINE_CHARS = 200;

export type CommandResult = { ok: true; lines: string[] } | { ok: false; reason: string };

const clip = (l: string) => (l.length <= MAX_LINE_CHARS ? l : `${l.slice(0, MAX_LINE_CHARS - 1)}…`);

/** Runs one command source. A non-zero exit, a timeout or a program that cannot start yields no lines and the reason, naming the source. */
export function commandLines(argv: string[], sinceSeconds: number, label: string, timeoutMs = COMMAND_TIMEOUT_MS): Promise<CommandResult> {
  const [program, ...args] = argv;
  if (program === undefined || program === "") return Promise.resolve({ ok: false, reason: `${label}: no program` });
  return new Promise((resolve) => {
    execFile(
      program,
      [...args, "--since", String(Math.floor(sinceSeconds))],
      { encoding: "utf8", maxBuffer: 16 * 1024 * 1024, timeout: timeoutMs, killSignal: "SIGKILL" },
      (error, stdout) => {
        if (error) {
          const e = error as Error & { killed?: boolean; code?: unknown };
          if (e.killed === true) return resolve({ ok: false, reason: `${label}: still running after ${Math.round(timeoutMs / 1000)} seconds` });
          if (typeof e.code === "number") return resolve({ ok: false, reason: `${label} exited ${e.code}` });
          return resolve({ ok: false, reason: `${label}: ${e.message}` });
        }
        const lines = stdout
          .split("\n")
          .map((l) => l.trim())
          .filter((l) => l !== "")
          .slice(0, MAX_COMMAND_LINES)
          .map(clip);
        resolve({ ok: true, lines });
      },
    );
  });
}
