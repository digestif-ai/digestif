// DIG-319: the binding the Durable Object suite adds to the Worker's Env (src/bindings.d.ts), set by
// spike/apply-migrations.ts under vitest.do.config.ts only.
declare global {
  interface Env {
    /** The local D1 kept beside the store under vitest.do.config.ts, for side-by-side checks. */
    D1?: D1Database;
  }
}

export {};
