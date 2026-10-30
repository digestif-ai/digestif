// The Worker's surface before any envelope: routes, error shapes, and the shared crypto in workerd.
import { env, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { envelopeHash, verifyEnvelope, type SignedEnvelope } from "../../conformance/src/envelope.ts";
import circleFile from "../../conformance/fixtures/test-circle.json";
import worker from "../src/index.ts";

describe("the shared conformance modules under nodejs_compat", () => {
  it("hash and verify the test circle's root dinner inside workerd", () => {
    const { envelope } = circleFile.root as SignedEnvelope;
    expect(envelopeHash(envelope)).toBe(circleFile.root_hash);
    expect(verifyEnvelope(envelope)).toBe(true);
    expect(verifyEnvelope({ ...envelope, seq: 2 })).toBe(false);
  });
});

describe("routes", () => {
  it("answers 401 not_admitted to an unsigned GET /v0/circle", async () => {
    const response = await SELF.fetch("http://relay.test/v0/circle");
    expect(response.status).toBe(401);
    expect(await response.json()).toMatchObject({ code: "not_admitted" });
  });

  it("answers 401 not_admitted to an unsigned GET /v0/envelopes", async () => {
    const response = await SELF.fetch("http://relay.test/v0/envelopes?after=0");
    expect(response.status).toBe(401);
    expect(await response.json()).toMatchObject({ code: "not_admitted" });
  });

  it("answers 404 with a relay_error to anything else", async () => {
    for (const [method, path] of [
      ["GET", "/"],
      ["GET", "/v0/nothing"],
      ["DELETE", "/v0/envelopes"],
      ["GET", "/v0/invites/"],
    ]) {
      const response = await SELF.fetch(`http://relay.test${path}`, { method });
      expect(response.status, `${method} ${path}`).toBe(404);
      expect(await response.json()).toMatchObject({ code: "malformed" });
    }
  });

  it("answers 404 not_mailer on the mailer routes when MAILER is not \"1\"", async () => {
    for (const mailer of [undefined, "0", "true"]) {
      for (const [method, path] of [
        ["POST", "/v0/mail"],
        ["GET", "/v0/links/abc?s=def"],
        ["POST", "/v0/links/abc"],
      ]) {
        const response = await worker.fetch(new Request(`http://relay.test${path}`, { method }), { ...env, MAILER: mailer });
        expect(response.status, `${method} ${path} with MAILER ${String(mailer)}`).toBe(404);
        expect(await response.json()).toMatchObject({ code: "not_mailer" });
      }
    }
  });

  it("answers 500 when MAILER is on without its secrets", async () => {
    for (const missing of ["RELAY_SEALING_KEY", "RESEND_API_KEY"]) {
      const response = await worker.fetch(new Request("http://relay.test/v0/links/abc?s=def"), { ...env, [missing]: undefined });
      expect(response.status, missing).toBe(500);
      expect(await response.text()).toContain(missing);
    }
  });

  it("writes the circle row from CIRCLE_ROOT on first use", async () => {
    await SELF.fetch("http://relay.test/v0/circle");
    const row = await env.DB.prepare("SELECT root, epoch FROM circle WHERE id = 1").first<{ root: string; epoch: number }>();
    expect(row).toEqual({ root: env.CIRCLE_ROOT, epoch: 0 });
  });
});
