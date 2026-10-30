// The Worker's bindings and variables (wrangler.jsonc). Runtime types come from `wrangler types`
// (worker-configuration.d.ts, generated, not checked in), which `npm run check` and `npm test` run.
import type { D1Migration } from "cloudflare:test";

declare global {
  interface Env {
    DB: D1Database;
    /** sha256:<hex> of the founding dinner envelope this relay serves. */
    CIRCLE_ROOT: string;
    MAX_ENVELOPE_BYTES?: string;
    MAX_APPENDS_PER_DEVICE_PER_DAY?: string;
    MAX_PAGE_SIZE?: string;
    SKEW_SECONDS?: string;
    /** Test only: the migrations vitest applies (vitest.config.ts). */
    TEST_MIGRATIONS?: D1Migration[];
  }

  namespace Cloudflare {
    // eslint-disable-next-line @typescript-eslint/no-empty-object-type
    interface Env extends globalThis.Env {}
  }
}

export {};
