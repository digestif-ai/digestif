// The home circle the tests run against: wrangler.jsonc's top-level CIRCLE_ROOT, the conformance
// suite's test circle, which the Worker under test reads as its home while HOME_ROOT is unset.
import { env } from "cloudflare:test";
import { DEFAULT_HOSTING } from "../src/env.ts";

const root = env.CIRCLE_ROOT;
if (root === undefined) throw new Error("wrangler.jsonc's top level names no CIRCLE_ROOT for the tests");

export const TEST_ROOT: string = root;

/** The home circle's address on the relay under test: every circle route answers only there. */
export const HOME = `http://relay.test/c/${root.slice("sha256:".length)}`;

/** What a Relay context holds besides its database, root, limits, clock, mailer and signers: the home circle's address and registry. */
export function relayExtras(): { address: string; hosting: typeof DEFAULT_HOSTING; registry: D1Database } {
  return { address: HOME, hosting: DEFAULT_HOSTING, registry: env.DB };
}
