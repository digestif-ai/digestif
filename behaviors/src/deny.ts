// The member's deny list in the code step of the PII check (docs/design.md, Guarding what goes
// out): names, domains, ids and patterns, matched exactly as node/web/deny.ml matches them at
// signing, so a version the check has cleaned never trips the node's backstop. A name or id
// matches as a whole word, case-insensitively; a domain anywhere, case-insensitively; a pattern is
// a regular expression, case-insensitive. The circle's own member and agent names never match a
// name entry.

import type { Found } from "./pii.ts";

/** One entry of the deny list, as `GET /rules/deny` answers it (spec/digestif-node.json). */
export interface DenyEntry {
  kind: "name" | "domain" | "id" | "pattern";
  value: string;
}

/** The type the Log names a deny list match by: never the entry, never the text. */
export const DENY_TYPE = "deny list";

function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** The entry as a global, case-insensitive expression, or undefined when it cannot match. */
function entryPattern(e: DenyEntry): RegExp | undefined {
  if (e.value === "") return undefined;
  switch (e.kind) {
    case "domain":
      return new RegExp(escapeRegExp(e.value), "gi");
    case "pattern":
      try {
        return new RegExp(e.value, "gi");
      } catch {
        return undefined;
      }
    default:
      // deny.ml's word characters are ASCII letters, digits and the underscore.
      return new RegExp(String.raw`(?<![A-Za-z0-9_])${escapeRegExp(e.value)}(?![A-Za-z0-9_])`, "gi");
  }
}

/** Every match of every entry, in order of where it starts. */
export function findDenied(text: string, entries: DenyEntry[], allowed: string[] = []): Found[] {
  const circle = new Set(allowed.map((n) => n.trim().toLowerCase()));
  const found: Found[] = [];
  for (const e of entries) {
    if (e.kind === "name" && circle.has(e.value.toLowerCase())) continue;
    const re = entryPattern(e);
    if (re === undefined) continue;
    for (const m of text.matchAll(re)) {
      if (m[0] !== "") found.push({ start: m.index, end: m.index + m[0].length, type: DENY_TYPE });
    }
  }
  return found.sort((a, b) => a.start - b.start);
}

/** Reads `GET /rules/deny`'s answer; anything that is not an entry is left out. */
export function readDenyList(body: unknown): DenyEntry[] {
  if (!Array.isArray(body)) return [];
  return body.flatMap((x: unknown) => {
    const { kind, value } = (x ?? {}) as { kind?: unknown; value?: unknown };
    return (kind === "name" || kind === "domain" || kind === "id" || kind === "pattern") && typeof value === "string" ? [{ kind, value }] : [];
  });
}
