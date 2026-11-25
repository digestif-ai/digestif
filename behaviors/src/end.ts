// Ending a hook on a signal, whatever its file system calls are doing (DIG-483).

import { killFolderReaders } from "./folders.ts";
import { killHarnesses } from "./writer.ts";

/**
 * Ends this process now with `code`. process.exit joins libuv's threads, so one blocked in a file
 * system call keeps the process from ending; replacing the process ends every thread without waiting
 * for it. The caller has ended what it alone started.
 */
export function endNow(code: number): never {
  killFolderReaders();
  killHarnesses();
  try {
    process.execve!("/bin/sh", ["sh", "-c", `exit ${code}`], {});
  } catch {
    // A platform that cannot replace a process: end it the ordinary way.
  }
  process.exit(code);
}
