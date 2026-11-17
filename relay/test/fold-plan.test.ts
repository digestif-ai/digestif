// The statements foldLog runs on every append read the circle-state envelopes and the one retract
// target through indexes, never by walking the log: D1 bills each row a statement reads. The log
// here is synthetic (no test folds it) and ANALYZE'd, so the planner sees a log of mostly content
// envelopes, the shape under which it prefers the primary key when nothing pins the index.
import { env } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";
import { CIRCLE_STATE_SQL, INCLUDED_SQL } from "../src/db.ts";

async function plan(sql: string, ...binds: (string | number)[]): Promise<string> {
  const { results } = await env.DB.prepare(`EXPLAIN QUERY PLAN ${sql}`).bind(...binds).all<{ detail: string }>();
  return results.map((row) => row.detail).join("\n");
}

beforeAll(async () => {
  const insert = env.DB.prepare(
    "INSERT INTO envelopes (hash, author, seq, kind, epoch, created_at, received_at, envelope, body) VALUES (?, 'author', ?, ?, 0, 'x', 'x', '{}', '{}')",
  );
  const rows = Array.from({ length: 2000 }, (_, i) => insert.bind(`h${i}`, i, i % 100 === 0 ? "join" : "summary"));
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
    const detail = await plan(INCLUDED_SQL, "h7", Number.MAX_SAFE_INTEGER);
    expect(detail).toMatch(/USING INDEX sqlite_autoindex_envelopes_\d+ \(hash=\?/);
  });

  it("would walk the log without the pinned index", async () => {
    const detail = await plan(CIRCLE_STATE_SQL.replace(" INDEXED BY envelopes_kind_relay_id", ""), Number.MAX_SAFE_INTEGER);
    expect(detail).toContain("INTEGER PRIMARY KEY");
  });
});
