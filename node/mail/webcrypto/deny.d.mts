// Types for deny.mjs, for the TypeScript that imports it (the phone web app).

/** One entry of the member's deny list, as their node publishes it (docs/protocol.md, The phone). */
export interface DenyEntry {
  kind: string;
  value: string;
}

/** The text as its UTF-8 bytes, one character per byte: the form every check reads. */
export function bytesOf(text: string): string;

/** A Perl-style pattern as ocaml-re reads it, as a JavaScript RegExp source over bytesOf text, or undefined. */
export function translatePattern(pattern: string): string | undefined;

/** The built-in detectors, in the order the node runs them. */
export const DETECTORS: { name: string; test(text: string): boolean | Promise<boolean> }[];

/**
 * The deny layer over one outbound text: undefined when it passes, else the rule that tripped,
 * "deny: <kind>" or "detector: <name>", exactly as node/web/deny.ml names it.
 */
export function denyCheck(text: string, entries: DenyEntry[], allowed?: string[]): Promise<string | undefined>;
