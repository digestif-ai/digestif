// DIG-319: the suite's env.DB becomes the circle's Durable Object behind the adapter, and the
// migrations are applied through it. The local D1 stays bound as D1, so a test can measure both.
import { applyD1Migrations, env } from "cloudflare:test";
import { storeOf } from "./main.ts";

const bound: Env = env;
if (bound.D1 === undefined) {
  bound.D1 = env.DB;
  bound.DB = storeOf(env);
}
await applyD1Migrations(bound.DB, env.TEST_MIGRATIONS ?? []);
await applyD1Migrations(bound.D1, env.TEST_MIGRATIONS ?? []);
