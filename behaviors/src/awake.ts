// Time that stops while the machine sleeps. A nightly run on a laptop can be put to sleep in the
// middle of a step (a maintenance DarkWake lets it start, the lid stays shut), and a wall-clock
// timer reads the sleep as work: the step looks hung the moment the machine next wakes. Every
// limit a run keeps (the writer's silence, the node's deadline) is measured on this clock instead.
//
// The clock is read every TICK_MS. Two readings further apart than SLEEP_GAP_MS mean the process
// did not run in between, so the gap counts as sleep, not as time spent.

import { spawn, type ChildProcess } from "node:child_process";

export const TICK_MS = 1_000;
export const SLEEP_GAP_MS = 10_000;

export class AwakeClock {
  #awake = 0;
  #slept = 0;
  #last: number;
  #timer: NodeJS.Timeout | undefined;
  readonly #now: () => number;

  constructor(now: () => number = Date.now) {
    this.#now = now;
    this.#last = now();
  }

  /** Milliseconds awake since the clock was made, reading the wall clock now. */
  read(): number {
    const t = this.#now();
    const d = t - this.#last;
    this.#last = t;
    if (d > SLEEP_GAP_MS) this.#slept += d;
    else if (d > 0) this.#awake += d;
    return this.#awake;
  }

  /** Milliseconds the machine slept (or the process was stopped) since the clock was made. */
  slept(): number {
    this.read();
    return this.#slept;
  }

  /** Reads the clock every TICK_MS until stop(), so a sleep shows as one gap. Keeps no process alive. */
  start(): this {
    this.#timer ??= setInterval(() => this.read(), TICK_MS).unref();
    return this;
  }

  stop(): void {
    if (this.#timer !== undefined) clearInterval(this.#timer);
    this.#timer = undefined;
  }
}

type Spawn = (cmd: string, args: string[], opts: { stdio: "ignore" }) => ChildProcess;

/**
 * Keeps the machine from idle-sleeping while this process runs: `caffeinate -i -w <pid>` on macOS,
 * which lets go when the process exits. Nothing elsewhere. A machine that sleeps anyway (the lid
 * closed, the battery low) pauses the run; the AwakeClock does not count the pause.
 */
export function holdAwake(platform: NodeJS.Platform = process.platform, run: Spawn = spawn, pid = process.pid): ChildProcess | undefined {
  if (platform !== "darwin") return undefined;
  try {
    const child = run("/usr/bin/caffeinate", ["-i", "-w", String(pid)], { stdio: "ignore" });
    child.on("error", () => {});
    child.unref();
    return child;
  } catch {
    return undefined;
  }
}
