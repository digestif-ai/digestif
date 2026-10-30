// The launchd agent that runs the nightly pipeline until the node spawns behaviors itself (#54).

import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const LABEL = "com.digestif.nightly";
export const TEMPLATE = join(dirname(fileURLToPath(import.meta.url)), "..", "launchd", `${LABEL}.plist.in`);

export const xml = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

export interface PlistValues {
  /** The program and its arguments, in order. */
  program: string[];
  path: string;
  stateDir: string;
}

/** Fills the template: every value XML-escaped; a placeholder left over is an error. */
export function renderPlist(template: string, v: PlistValues): string {
  const args = v.program.map((a) => `    <string>${xml(a)}</string>`).join("\n");
  const out = template
    .replace("@PROGRAM_ARGUMENTS@", () => args)
    .replace(/@PATH@/g, () => xml(v.path))
    .replace(/@STATE_DIR@/g, () => xml(v.stateDir));
  const left = /@[A-Z_]+@/.exec(out);
  if (left) throw new Error(`unfilled placeholder ${left[0]}`);
  return out;
}

export async function loadTemplate(): Promise<string> {
  return readFile(TEMPLATE, "utf8");
}
