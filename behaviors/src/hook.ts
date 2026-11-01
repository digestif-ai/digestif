// Hook mode: the nightly run as the node's behavior (docs/behaviors.md). The node spawns it with
// DIGESTIF_HOOK set and one JSON object on stdin, owns the fixed minute and the once-per-date logic,
// and ends the run at the deadline (SIGTERM, then SIGKILL 30 seconds later). The exit status tells
// the node whether the date is over: 0 it is (posted, quiet, refused, signed out, or the tries are
// spent), 1 the run failed and the node's next pass tries again.

import { readFile } from "node:fs/promises";
import { holdAwake } from "./awake.ts";
import { countFailureSync, hookStateDir, logLineSync, MAX_ATTEMPTS, nightly, type NightlyOptions } from "./nightly.ts";
import type { Source, SourceKind } from "./sources.ts";
import { fetchContext, killHarnesses, type ApiAccess, type WriterOptions } from "./writer.ts";

/** The handoff's `interface` this code understands. */
export const INTERFACE = 0;

/** The handoff, as docs/behaviors.md describes it, checked. */
export interface Handoff {
  localDate: string;
  dataDir: string;
  digestif: string;
  api: ApiAccess | null;
  /** Every source handed over is chosen. Kinds this suite cannot read are left out. */
  sources: Source[];
  deadline: Date;
}

/** Thrown for a handoff this behavior refuses; the exit status is 2. */
export class HandoffError extends Error {}

const isStr = (v: unknown): v is string => typeof v === "string";
const isStrArray = (v: unknown): v is string[] => Array.isArray(v) && v.every(isStr);
const KINDS: SourceKind[] = ["claude_code", "git", "command"];

export function parseHandoff(text: string): Handoff {
  let j: unknown;
  try {
    j = JSON.parse(text);
  } catch {
    throw new HandoffError("stdin is not a JSON object");
  }
  if (typeof j !== "object" || j === null || Array.isArray(j)) throw new HandoffError("stdin is not a JSON object");
  const o = j as Record<string, unknown>;
  if (o["interface"] !== INTERFACE) throw new HandoffError(`interface ${JSON.stringify(o["interface"])} is not one this behavior speaks (${INTERFACE})`);
  if (o["hook"] !== "nightly") throw new HandoffError(`hook ${JSON.stringify(o["hook"])} is not "nightly"`);
  const localDate = o["local_date"];
  if (!isStr(localDate) || !/^\d{4}-\d{2}-\d{2}$/.test(localDate)) throw new HandoffError("local_date must be YYYY-MM-DD");
  if (!isStr(o["data_dir"]) || o["data_dir"] === "") throw new HandoffError("data_dir must be a path");
  if (!isStr(o["digestif"]) || o["digestif"] === "") throw new HandoffError("digestif must be a path");
  let api: ApiAccess | null = null;
  if (o["api"] !== null && o["api"] !== undefined) {
    const a = o["api"] as Record<string, unknown>;
    const h = a["headers"];
    if (typeof a !== "object" || !isStr(a["url"]) || typeof h !== "object" || h === null || !Object.values(h).every(isStr)) {
      throw new HandoffError("api must be null or { url, headers }");
    }
    api = { url: a["url"], headers: h as Record<string, string> };
  }
  if (!Array.isArray(o["sources"])) throw new HandoffError("sources must be a list");
  const sources: Source[] = [];
  for (const s of o["sources"] as Record<string, unknown>[]) {
    if (typeof s !== "object" || s === null || !isStr(s["id"]) || !isStr(s["kind"]) || !isStrArray(s["paths"])) {
      throw new HandoffError("every source needs an id, a kind and paths");
    }
    if (!KINDS.includes(s["kind"] as SourceKind)) continue;
    sources.push({
      id: s["id"],
      kind: s["kind"] as SourceKind,
      label: isStr(s["label"]) ? s["label"] : s["id"],
      paths: s["paths"],
      yields: isStrArray(s["yields"]) ? s["yields"] : [],
      selected: true,
    });
  }
  const deadline = new Date(isStr(o["deadline"]) ? o["deadline"] : NaN);
  if (Number.isNaN(deadline.getTime())) throw new HandoffError("deadline must be a time");
  return { localDate, dataDir: o["data_dir"], digestif: o["digestif"], api, sources, deadline };
}

/** What `config.json` may carry: the names are the flags'. */
export interface HookConfig {
  harness?: string;
  /** A file, as `--brief`. Overrides the brief the API serves. */
  brief?: string;
  /** A file, as `--rules`. */
  rules?: string;
  allow?: string[];
}

/** `<data_dir>/behaviors/nightly/config.json`; absent means defaults. */
export async function readConfig(stateDir: string): Promise<HookConfig> {
  const file = `${stateDir}/config.json`;
  let raw: string;
  try {
    raw = await readFile(file, "utf8");
  } catch {
    return {};
  }
  let j: unknown;
  try {
    j = JSON.parse(raw);
  } catch {
    throw new HandoffError(`${file} is not JSON`);
  }
  const c = j as Record<string, unknown>;
  if (typeof j !== "object" || j === null || Array.isArray(j)) throw new HandoffError(`${file} must be a JSON object`);
  for (const k of ["harness", "brief", "rules"]) if (c[k] !== undefined && !isStr(c[k])) throw new HandoffError(`${file}: ${k} must be a string`);
  if (c["allow"] !== undefined && !isStrArray(c["allow"])) throw new HandoffError(`${file}: allow must be a list of names`);
  return c;
}

/** Runs one hook invocation from its stdin text. Returns the exit status: 0, 1 a failed run, 2 refused. */
export async function runHook(stdin: string, env: NodeJS.ProcessEnv = process.env): Promise<number> {
  let h: Handoff;
  let stateDir: string;
  let config: HookConfig;
  try {
    if (env["DIGESTIF_HOOK"] !== "nightly") throw new HandoffError(`DIGESTIF_HOOK is ${JSON.stringify(env["DIGESTIF_HOOK"])}, not "nightly"`);
    h = parseHandoff(stdin);
    stateDir = hookStateDir(h.dataDir);
    config = await readConfig(stateDir);
  } catch (e) {
    console.error(`digestif-nightly: ${(e as Error).message}`);
    return 2;
  }

  // The node's deadline is a SIGTERM. End the harness's whole process group, count the try, say
  // where, and go.
  let step = "start";
  process.once("SIGTERM", () => {
    killHarnesses();
    try {
      const count = countFailureSync(stateDir, h.localDate);
      logLineSync(stateDir, h.localDate, `killed by SIGTERM at ${step} (try ${count}/${MAX_ATTEMPTS})`);
    } catch {
      /* the log is best effort; the exit is not */
    }
    process.exit(143);
  });
  // Idle sleep would pause the run mid-step; hold it off for the run's length.
  holdAwake();

  try {
    const writer: WriterOptions = {
      ...(config.harness === undefined ? {} : { harness: config.harness }),
      ...(config.brief === undefined ? {} : { brief: await readFile(config.brief, "utf8") }),
      ...(config.rules === undefined ? {} : { rules: await readFile(config.rules, "utf8") }),
    };
    const options: NightlyOptions = {
      stateDir,
      selection: { sources: h.sources },
      now: new Date(),
      hookDate: h.localDate,
      deadline: h.deadline,
      onStep: (s) => (step = s),
      node: h.digestif,
      allow: config.allow ?? [],
      writer,
      context: () => fetchContext(h.api),
    };
    const r = await nightly(options);
    console.error(`digestif-nightly: ${r.status} (${r.date})`);
    return r.status === "failed" ? 1 : 0;
  } catch (e) {
    console.error(`digestif-nightly: ${(e as Error).message}`);
    return 1;
  }
}
