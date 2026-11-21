// The statements foldLog runs on every append read the circle-state envelopes and the one retract
// target through indexes, and the answer-link page reads one item's decisions, never by walking the
// log: D1 bills each row a statement reads. The log
// here is synthetic (no test folds it) and ANALYZE'd, so the planner sees a log of mostly content
// envelopes, the shape under which it prefers the primary key when nothing pins the index.
import { env } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";
import { CIRCLE_STATE_SQL, RETRACT_TARGET_SQL } from "../src/db.ts";
import { ANSWERED_SQL } from "../src/links.ts";

async function plan(sql: string, ...binds: (string | number)[]): Promise<string> {
  const { results } = await env.DB.prepare(`EXPLAIN QUERY PLAN ${sql}`).bind(...binds).all<{ detail: string }>();
  return results.map((row) => row.detail).join("\n");
}

beforeAll(async () => {
  const kindOf = (i: number): string => (i % 100 === 0 ? "join" : i % 3 === 0 ? "decision" : "summary");
  const insert = env.DB.prepare(
    "INSERT INTO envelopes (hash, author, seq, kind, epoch, created_at, received_at, envelope, body) VALUES (?, 'author', ?, ?, 0, 'x', 'x', '{}', ?)",
  );
  const rows = Array.from({ length: 2000 }, (_, i) => insert.bind(`h${i}`, i, kindOf(i), JSON.stringify({ item: `item${i}` })));
  await env.DB.batch(rows);
  await env.DB.exec("ANALYZE");
});

describe("the fold's reads", () => {
  it("read the circle-state envelopes through envelopes_kind_relay_id", async () => {
    const detail = await plan(CIRCLE_STATE_SQL, Number.MAX_SAFE_INTEGER);
    expect(detail).toContain("USING INDEX envelopes_kind_relay_id");
    expect(detail).not.toContain("INTEGER PRIMARY KEY");
  });

  it("read the retract target by its hash", async () => {
    const detail = await plan(RETRACT_TARGET_SQL, "h7");
    expect(detail).toMatch(/USING INDEX sqlite_autoindex_envelopes_\d+ \(hash=\?/);
  });

  it("would walk the log without the pinned index", async () => {
    const detail = await plan(CIRCLE_STATE_SQL.replace(" INDEXED BY envelopes_kind_relay_id", ""), Number.MAX_SAFE_INTEGER);
    expect(detail).toContain("INTEGER PRIMARY KEY");
  });
});

describe("the answer-link page's read", () => {
  it("finds a decision on an item through envelopes_decision_item, not by reading every decision", async () => {
    const detail = await plan(ANSWERED_SQL, "item3", "author");
    expect(detail).toContain("USING INDEX envelopes_decision_item");
    expect(detail).not.toMatch(/SCAN e\b/);
  });
});
