// The free-write-pool probe (DIG-320): one SQLite Durable Object and one D1 database behind one
// Worker, so run.sh can spend a Workers Free account's Durable Object rows-written allowance and
// then ask D1 for a write. Every route answers 200 with JSON, a refused write included, so the
// error text Cloudflare returns reaches run.sh verbatim.
//
//   POST /do/write?n=N   insert N rows into the object's table; { ok, rowsWritten } or { ok: false, error }
//   POST /d1/write       insert one row into D1;                  { ok, rowsWritten } or { ok: false, error }
//
// The tables carry no index, so a row inserted is one row written.
import { DurableObject } from "cloudflare:workers";

export class Pool extends DurableObject {
  write(n) {
    const sql = this.ctx.storage.sql;
    sql.exec("CREATE TABLE IF NOT EXISTS t (v INTEGER)");
    const cursor = sql.exec(
      "INSERT INTO t (v) WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < ?) SELECT x FROM c",
      n,
    );
    cursor.toArray();
    return cursor.rowsWritten;
  }
}

async function answer(work) {
  try {
    return Response.json({ ok: true, rowsWritten: await work() });
  } catch (e) {
    return Response.json({ ok: false, error: String(e && e.message ? e.message : e) });
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method !== "POST") return new Response("POST only\n", { status: 405 });
    if (url.pathname === "/do/write") {
      const n = Number.parseInt(url.searchParams.get("n") ?? "1", 10);
      if (!Number.isInteger(n) || n < 1 || n > 100000) return new Response("n is 1..100000\n", { status: 400 });
      const stub = env.POOL.get(env.POOL.idFromName("probe"));
      return answer(() => stub.write(n));
    }
    if (url.pathname === "/d1/write") {
      return answer(async () => {
        const results = await env.DB.batch([
          env.DB.prepare("CREATE TABLE IF NOT EXISTS t (v INTEGER)"),
          env.DB.prepare("INSERT INTO t (v) VALUES (?)").bind(Date.now()),
        ]);
        return results.reduce((sum, r) => sum + (r.meta.rows_written ?? 0), 0);
      });
    }
    return new Response("not found\n", { status: 404 });
  },
};
