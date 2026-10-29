// Case registry, assertions and the runner. A case is an id, the line of docs/protocol.md
// "Conformance cases" it covers, and a function that throws on the first broken expectation.
import type { HttpResult } from "./request.ts";

export interface Case<Context> {
  id: string;
  /** The line of docs/protocol.md "Conformance cases" this proves. */
  covers: string;
  title: string;
  /** How many relays the case needs; it is skipped, not failed, when fewer are configured. */
  relays?: number;
  run(context: Context): Promise<void>;
}

export class Failure extends Error {}

export function check(condition: boolean, message: string): asserts condition {
  if (!condition) throw new Failure(message);
}

export function equal<T>(actual: T, expected: T, what: string): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Failure(`${what}: expected ${e}, got ${a}`);
}

function describe(result: HttpResult): string {
  return `${result.request.method} ${new URL(result.request.url).pathname} answered ${result.status} ${result.text.slice(0, 300)}`;
}

export function accepted(result: HttpResult, what: string): void {
  if (result.status !== 201) throw new Failure(`${what}: expected 201 accepted; ${describe(result)}`);
  const body = result.body as { status?: string } | undefined;
  if (body?.status !== "accepted") throw new Failure(`${what}: expected status accepted; ${describe(result)}`);
}

export function ok(result: HttpResult, what: string): void {
  if (result.status !== 200) throw new Failure(`${what}: expected 200; ${describe(result)}`);
}

/** The relay_error codes in a response, whether the body is one error (401, 429) or a list (422). */
export function errorCodes(result: HttpResult): string[] {
  const body = result.body;
  const list = Array.isArray(body) ? body : body === undefined ? [] : [body];
  return list.map((e) => (e as { code?: string })?.code).filter((c): c is string => typeof c === "string");
}

/** A refusal: one of the allowed statuses, carrying one of the allowed codes. */
export function refused(result: HttpResult, statuses: number[], code: string | string[], what: string): void {
  const codes = Array.isArray(code) ? code : [code];
  if (!statuses.includes(result.status) || !errorCodes(result).some((c) => codes.includes(c))) {
    throw new Failure(`${what}: expected ${statuses.join(" or ")} with code ${codes.join(" or ")}; ${describe(result)}`);
  }
}

export interface Outcome {
  id: string;
  result: "pass" | "fail" | "skip";
  message?: string;
  ms: number;
}

export interface RunOptions<Context> {
  cases: Case<Context>[];
  only?: string[];
  relayCount: number;
  context: (c: Case<Context>) => Promise<{ value: Context; close?: () => Promise<void> }>;
  log?: (line: string) => void;
}

function matches(id: string, patterns: string[] | undefined): boolean {
  if (patterns === undefined || patterns.length === 0) return true;
  return patterns.some((p) => {
    const regex = new RegExp(`^${p.split("*").map((s) => s.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join(".*")}$`);
    return regex.test(id) || id.startsWith(`${p}.`);
  });
}

/** Runs cases in order, one at a time, printing TAP. */
export async function runCases<Context>(options: RunOptions<Context>): Promise<Outcome[]> {
  const log = options.log ?? ((line: string) => console.log(line));
  const selected = options.cases.filter((c) => matches(c.id, options.only));
  const outcomes: Outcome[] = [];
  log(`TAP version 14`);
  log(`1..${selected.length}`);
  for (const [index, c] of selected.entries()) {
    const started = Date.now();
    const number = index + 1;
    if ((c.relays ?? 1) > options.relayCount) {
      const message = `needs ${c.relays} relays, ${options.relayCount} configured`;
      outcomes.push({ id: c.id, result: "skip", message, ms: 0 });
      log(`ok ${number} - ${c.id} # SKIP ${message}`);
      continue;
    }
    let context: { value: Context; close?: () => Promise<void> } | undefined;
    try {
      context = await options.context(c);
      await c.run(context.value);
      const ms = Date.now() - started;
      outcomes.push({ id: c.id, result: "pass", ms });
      log(`ok ${number} - ${c.id} (${ms} ms)`);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      outcomes.push({ id: c.id, result: "fail", message, ms: Date.now() - started });
      log(`not ok ${number} - ${c.id}`);
      log(`  ---`);
      log(`  covers: ${JSON.stringify(c.covers)}`);
      log(`  message: ${JSON.stringify(message)}`);
      if (!(error instanceof Failure) && error instanceof Error && error.stack) log(`  stack: ${JSON.stringify(error.stack)}`);
      log(`  ...`);
    } finally {
      await context?.close?.();
    }
  }
  const failed = outcomes.filter((o) => o.result === "fail").length;
  const skipped = outcomes.filter((o) => o.result === "skip").length;
  log(`# pass ${outcomes.length - failed - skipped}, fail ${failed}, skip ${skipped}`);
  return outcomes;
}
