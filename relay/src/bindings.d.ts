// The Worker's bindings and variables (wrangler.jsonc). Runtime types come from `wrangler types`
// (worker-configuration.d.ts, generated, not checked in), which `npm run check` and `npm test` run.
import type { D1Migration } from "cloudflare:test";

declare global {
  interface Env {
    DB: D1Database;
    /** sha256:<hex> of the root envelope (a circle, or a founding dinner) of the circle this relay serves. */
    CIRCLE_ROOT: string;
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
    /** Where /install.sh is read from: the newest published release's install.sh (src/install.ts). Unset: no /install.sh. */
    INSTALL_SCRIPT_URL?: string;
    /**
     * A digestif-signers-v0 document the admission fold starts from in place of the build's
     * node/update/release-signers.json (src/signers.ts): set at wrangler.jsonc's top level only, to
     * the conformance suite's public test signers. No deployed environment sets it.
     */
    RELEASE_SIGNERS?: string;
    /** The circle's bare domain, which answers /install.sh and nothing else. */
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
