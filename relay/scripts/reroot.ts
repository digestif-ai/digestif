// Decides whether a deploy re-roots a database (README "Re-root"): scripts/deploy.sh reads the
// remote circle row and the log size with CIRCLE_QUERY, pipes wrangler's --json output here, and
// acts on the verdict. Shared with test/deploy.test.ts.

/** One statement: the root the database serves (NULL before its first request) and the log size. */
export const CIRCLE_QUERY = "SELECT (SELECT root FROM circle WHERE id = 1) AS root, (SELECT COUNT(*) FROM envelopes) AS envelopes";

/** Clears the row only while it still names the old root and the log is still empty. */
export function clearStatement(oldRoot: string): string {
  if (!/^sha256:[0-9a-f]{64}$/.test(oldRoot)) throw new Error(`not a root hash: ${oldRoot}`);
  return `DELETE FROM circle WHERE id = 1 AND root = '${oldRoot}' AND NOT EXISTS (SELECT 1 FROM envelopes)`;
}

export type Verdict =
  | { kind: "fresh" } // no circle row: the first request writes the configured root
  | { kind: "same" } // the row names the configured root
  | { kind: "clear"; root: string } // another root over an empty log: safe to clear
  | { kind: "refuse"; root: string; envelopes: number }; // another circle's log: never mixed

/** Reads `wrangler d1 execute --json` output for CIRCLE_QUERY and compares it with the configured root. */
export function verdict(output: string, configured: string): Verdict {
  const start = output.search(/^\s*\[\s*[{\]]/m);
  if (start < 0) throw new Error(`no JSON in wrangler's output: ${output.trim()}`);
  const parsed = JSON.parse(output.slice(start)) as { results?: { root: string | null; envelopes: number }[] }[];
  const row = parsed[0]?.results?.[0];
  if (row === undefined) throw new Error("wrangler's output holds no result row");
  if (row.root === null) return { kind: "fresh" };
  if (row.root === configured) return { kind: "same" };
  return row.envelopes === 0 ? { kind: "clear", root: row.root } : { kind: "refuse", root: row.root, envelopes: row.envelopes };
}

// CLI: node scripts/reroot.ts query                 prints CIRCLE_QUERY
//      node scripts/reroot.ts clear <old root>      prints the clearing statement
//      node scripts/reroot.ts verdict <root> < out  prints "<kind> [root] [envelopes]"
if (typeof process !== "undefined" && process.argv[1]?.endsWith("reroot.ts") === true) {
  const { readFileSync } = await import("node:fs");
  const [command, arg] = process.argv.slice(2);
  if (command === "query") console.log(CIRCLE_QUERY);
  else if (command === "clear" && arg !== undefined) console.log(clearStatement(arg));
  else if (command === "verdict" && arg !== undefined) {
    const v = verdict(readFileSync(0, "utf8"), arg);
    console.log([v.kind, "root" in v ? v.root : "", "envelopes" in v ? v.envelopes : ""].join(" ").trim());
  } else throw new Error("usage: reroot.ts query | clear <old root> | verdict <root> < wrangler-output");
}
