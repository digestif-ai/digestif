// The release signer set a relay starts its admission fold from (docs/protocol.md, The admission
// fold): the node/update/release-signers.json this build carries, so a relay knows the set it judges
// admissions by and a relay release that carries a new file moves it. RELEASE_SIGNERS replaces it
// only where wrangler.jsonc's top level sets it, for the conformance suite's public test signers; no
// deployed environment sets it, and test/deploy.test.ts holds that.
import { signerKeysOf } from "../../conformance/src/admission.ts";
import { parseUnique } from "../../conformance/src/strict-json.ts";
import built from "../../node/update/release-signers.json";
import { ConfigError } from "./env.ts";

export function releaseSignersOf(env: Env): string[] {
  const override = env.RELEASE_SIGNERS;
  if (override === undefined || override === "") {
    const keys = signerKeysOf(built);
    if (keys === undefined) throw new ConfigError("node/update/release-signers.json is not a digestif-signers-v0 of at least two keys");
    return keys;
  }
  let parsed: unknown;
  try {
    parsed = parseUnique(override, "RELEASE_SIGNERS");
  } catch {
    throw new ConfigError("RELEASE_SIGNERS must be a digestif-signers-v0 document");
  }
  const keys = signerKeysOf(parsed as Parameters<typeof signerKeysOf>[0]);
  if (keys === undefined) throw new ConfigError("RELEASE_SIGNERS must be a digestif-signers-v0 of at least two keys, none twice");
  return keys;
}
