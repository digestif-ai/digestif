// relay_version on GET /v0/circle: the stamp vitest.config.ts defines, as the release build does,
// and the rule that an unstamped Worker reports no field at all.
import { SELF } from "cloudflare:test";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { type SignedEnvelope } from "../../conformance/src/envelope.ts";
import { Signer } from "../../conformance/src/keys.ts";
import { World } from "../../conformance/src/world.ts";
import circleFile from "../../conformance/fixtures/test-circle.json";
import { RELAY_VERSION, relayVersionOf } from "../src/version.ts";
import { RELAY } from "./helpers.ts";
import { TEST_RELAY_VERSION } from "./stamp.ts";

const realFetch = globalThis.fetch;

beforeAll(() => {
  globalThis.fetch = (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    return url.startsWith(RELAY) ? SELF.fetch(url, init) : realFetch(input, init);
  };
});

afterAll(() => {
  globalThis.fetch = realFetch;
});

describe("relay_version", () => {
  it("is the stamp when one was defined, and nothing for a missing, non-string or empty stamp", () => {
    expect(relayVersionOf("0.3.0")).toBe("0.3.0");
    expect(relayVersionOf(undefined)).toBeUndefined();
    expect(relayVersionOf("")).toBeUndefined();
    expect(relayVersionOf(3)).toBeUndefined();
  });

  it("is read from the stamp the build defines", () => {
    expect(RELAY_VERSION).toBe(TEST_RELAY_VERSION);
  });

  it("is reported by GET /v0/circle beside the limits", async () => {
    const world = new World(
      {
        hostIdentity: Signer.fromSeed(circleFile.host_identity_seed),
        hostDevice: Signer.fromSeed(circleFile.host_device_seed),
        root: circleFile.root as SignedEnvelope,
        rootHash: circleFile.root_hash,
      },
      [RELAY],
    );
    await world.setup();
    const result = await world.client(RELAY, world.host.device).circle();
    expect(result.status).toBe(200);
    expect(result.body).toMatchObject({ root: circleFile.root_hash, relay_version: TEST_RELAY_VERSION });
  });
});
