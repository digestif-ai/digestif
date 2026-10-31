// Whether a process the tests killed is gone. A killed process whose parent has exited is
// reparented to PID 1, and stays a zombie until PID 1 reaps it: launchd does at once, but a
// container's PID 1 often never does, so kill(pid, 0) goes on succeeding. A zombie runs nothing,
// so it counts as dead. ISS-35233
import { readFileSync } from "node:fs";

/** "R", "S", "Z", ... from /proc/<pid>/stat, or undefined where there is no /proc (macOS). */
function procState(pid: number): string | undefined {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
    // The command name is parenthesised and may itself hold spaces or parentheses.
    return stat.slice(stat.lastIndexOf(")") + 2).split(" ")[0];
  } catch {
    return undefined;
  }
}

function gone(pid: number): boolean {
  try {
    process.kill(pid, 0);
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ESRCH") return true;
    throw e;
  }
  return procState(pid) === "Z";
}

/** Resolves once `pid` no longer exists or is a zombie; rejects when it is still running at the deadline. */
export async function assertGone(pid: number, what: string, timeoutMs = 5000): Promise<void> {
  const until = Date.now() + timeoutMs;
  while (!gone(pid)) {
    if (Date.now() >= until) throw new Error(`${what} (pid ${pid}) is still running, state ${procState(pid) ?? "unknown"}`);
    await new Promise((r) => setTimeout(r, 20));
  }
}
