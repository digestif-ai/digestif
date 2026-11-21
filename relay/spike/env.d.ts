// DIG-319 storage spike: the bindings the spike adds to the Worker's Env (src/bindings.d.ts), set by
// vitest.do.config.ts and spike/wrangler.jsonc only. Kept here so the relay's release paths
// (ci/relay-release-paths) see no change from the spike.
import type { CircleStore } from "./store.ts";

declare global {
  interface Env {
    /** The circle's SQLite-backed Durable Object store. */
    CIRCLE_STORE?: DurableObjectNamespace<CircleStore>;
    /** The local D1 kept beside the store under vitest.do.config.ts, for side-by-side checks. */
    D1?: D1Database;
  }
}

export {};
