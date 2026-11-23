// DIG-319: the relay Worker with its store swapped for the circle's Durable Object (src/store.ts).
// src/index.ts runs unchanged; only the DB binding it is handed differs. The adapter is kept per
// isolate and root, as the D1 binding is, so the per-database checks src/db.ts keys on it hold.
import relay from "../src/index.ts";
import { circleDatabase } from "../src/store.ts";

export { CircleStore } from "../src/store.ts";

const handles = new Map<string, D1Database>();

/** The circle's store: the object named by CIRCLE_ROOT, one handle per isolate. */
export function storeOf(env: Env): D1Database {
  const root = env.CIRCLE_ROOT;
  if (root === undefined) throw new Error("the spike runs on wrangler.jsonc's top-level CIRCLE_ROOT");
  let db = handles.get(root);
  if (db === undefined) {
    db = circleDatabase(env.CIRCLE_STORE, root);
    handles.set(root, db);
  }
  return db;
}

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return relay.fetch(request, { ...env, DB: storeOf(env) });
  },
} satisfies ExportedHandler<Env>;
