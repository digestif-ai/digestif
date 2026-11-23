// The Worker's bindings and variables (wrangler.jsonc). Runtime types come from `wrangler types`
// (worker-configuration.d.ts, generated, not checked in), which `npm run check` and `npm test` run.
import type { D1Migration } from "cloudflare:test";
import type { CircleStore } from "./store.ts";

declare global {
  interface Env {
    DB: D1Database;
    /** The circles' stores: one SQLite-backed Durable Object per circle, named by its root (src/store.ts). */
    CIRCLE_STORE: DurableObjectNamespace<CircleStore>;
    /**
     * sha256:<hex> of the home circle's root (src/env.ts, homeOf): the operator's own circle, which
     * carries the relay's releases and answers the unprefixed routes. Unset on a freshly deployed
     * relay, which has no home; set by `digestif circle found --relay` and carried forward by every
     * deploy, never from a bundle.
     */
    HOME_ROOT?: string;
    /** The home circle while HOME_ROOT is unset: what a deployment configured before hosting names. */
    CIRCLE_ROOT?: string;
    /** "0" or "off" stops the relay opening new circles (not_hosting). */
    HOSTING?: string;
    /** Bytes every hosted circle's reserved share fits in together; 4 GiB when unset. */
    RELAY_STORAGE?: string;
    /** Bytes one circle's store may hold; 256 MiB when unset. */
    CIRCLE_STORAGE?: string;
    /** Circles one vouching member may open per 30 days; 5 when unset. */
    CIRCLES_PER_MEMBER?: string;
    /** Rows a day the home circle's move copies into its store; 20000 when unset, 0 to keep it on D1. */
    MOVE_ROWS_PER_DAY?: string;
    MAX_ENVELOPE_BYTES?: string;
    MAX_APPENDS_PER_DEVICE_PER_DAY?: string;
    MAX_PAGE_SIZE?: string;
    SKEW_SECONDS?: string;
    /** "1" on the one relay that mails (docs/protocol.md "Mailer routes"); any other value means it does not. */
    MAILER?: string;
    /** Secret: the mailing relay's X25519 private key, raw 32 bytes, base64url. */
    RELAY_SEALING_KEY?: string;
    /** Secret: Resend's API key. */
    RESEND_API_KEY?: string;
    /** The From header of the digest email. */
    MAIL_FROM?: string;
    /** The URL answer links name, when the relay is reached through another (a tunnel); the request origin otherwise. */
    RELAY_URL?: string;
    /**
     * A digestif-signers-v0 document the admission fold starts from in place of the build's
     * node/update/release-signers.json (src/signers.ts): set at wrangler.jsonc's top level only, to
     * the conformance suite's public test signers. No deployed environment sets it, and /install.sh
     * never reads it (src/install.ts).
     */
    RELEASE_SIGNERS?: string;
    /** The circle's bare domain, which answers /install.sh, rendered from the newest signed manifest (src/install.ts), and nothing else. Unset: no /install.sh. */
    SITE_HOST?: string;
    /** The per-address ceiling on POST /v0/envelopes (wrangler.jsonc, ratelimits), on the deployed environments only. */
    APPEND_LIMITER?: RateLimit;
    /** The static assets under /app/ (wrangler.jsonc, assets). */
    ASSETS: Fetcher;
    /** Test only: the migrations vitest applies (vitest.config.ts). */
    TEST_MIGRATIONS?: D1Migration[];
  }

  namespace Cloudflare {
    // eslint-disable-next-line @typescript-eslint/no-empty-object-type
    interface Env extends globalThis.Env {}
  }
}

export {};
