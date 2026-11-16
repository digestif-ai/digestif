// A command source's lines (docs/behaviors.md, Command sources): the member's program, run as its
// paths with --since and an ISO 8601 date time with its offset appended, one item per line of stdout. Mirrors command_lines in
// node/web/sources.ml: the same timeout, lines per source and line length.

import { execFile } from "node:child_process";

/** node/web/sources.ml, command_timeout, in milliseconds. */
export const COMMAND_TIMEOUT_MS = 30_000;
/** node/web/sources.ml, max_command_lines. */
export const MAX_COMMAND_LINES = 200;
/** node/web/sources.ml, max_line_chars. */
export const MAX_LINE_CHARS = 1000;

/**
 * A failed run says why twice: `reason` names the source, for the run's log, and `error` is the
 * cause in plain words for the member (DIG-127): the exit status with the last line the program
 * wrote to stderr, the time it was ended at, or why it could not start. Never a line of stdout.
 */
export type CommandResult = { ok: true; lines: string[] } | { ok: false; reason: string; error: string };

/** The most of a program's last stderr line the cause carries. */
export const MAX_ERROR_CHARS = 200;

/** The last non-empty line a program wrote to stderr, clipped; empty when it wrote none. */
export function lastErrorLine(stderr: string): string {
  const line = stderr.split("\n").map((l) => l.trim()).filter((l) => l !== "").pop() ?? "";
  return line.length <= MAX_ERROR_CHARS ? line : `${line.slice(0, MAX_ERROR_CHARS - 1)}…`;
}

const clip = (l: string) => (l.length <= MAX_LINE_CHARS ? l : `${l.slice(0, MAX_LINE_CHARS - 1)}…`);

/** Runs one command source. A non-zero exit, a timeout or a program that cannot start yields no lines and the reason, naming the source. */
export function commandLines(argv: string[], since: string, label: string, timeoutMs = COMMAND_TIMEOUT_MS): Promise<CommandResult> {
  const [program, ...args] = argv;
  if (program === undefined || program === "") return Promise.resolve({ ok: false, reason: `${label}: no program`, error: "it names no program" });
  return new Promise((resolve) => {
    execFile(
      program,
      [...args, "--since", since],
      { encoding: "utf8", maxBuffer: 16 * 1024 * 1024, timeout: timeoutMs, killSignal: "SIGKILL" },
      (error, stdout, stderr) => {
        if (error) {
          const e = error as Error & { killed?: boolean; code?: unknown };
          const said = lastErrorLine(stderr);
          if (e.killed === true) {
            const seconds = Math.round(timeoutMs / 1000);
            return resolve({ ok: false, reason: `${label}: still running after ${seconds} seconds`, error: `it was still running after ${seconds} seconds and was ended` });
          }
          if (typeof e.code === "number") return resolve({ ok: false, reason: `${label} exited ${e.code}`, error: `it exited with status ${e.code}${said === "" ? "" : ` (${said})`}` });
          const code = typeof e.code === "string" ? e.code : e.message;
          return resolve({ ok: false, reason: `${label}: ${e.message}`, error: `its program could not be started (${code})` });
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
