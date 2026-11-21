// DIG-319 storage spike: the relay Worker with its store swapped for the circle's Durable Object.
// src/index.ts runs unchanged; only the DB binding it is handed differs. The adapter is kept per
// isolate and root, as the D1 binding is, so the per-database checks src/db.ts keys on it hold.
import relay from "../src/index.ts";
import { CircleStore, circleDatabase } from "./store.ts";

export { CircleStore };

const handles = new Map<string, D1Database>();

/** The circle's store: the object named by CIRCLE_ROOT, one handle per isolate. */
export function storeOf(env: Env): D1Database {
  const namespace = env.CIRCLE_STORE;
  if (namespace === undefined) throw new Error("CIRCLE_STORE is not bound");
  let db = handles.get(env.CIRCLE_ROOT);
  if (db === undefined) {
    db = circleDatabase(namespace, env.CIRCLE_ROOT);
    handles.set(env.CIRCLE_ROOT, db);
  }
  return db;
}

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return relay.fetch(request, { ...env, DB: storeOf(env) });
  },
} satisfies ExportedHandler<Env>;
