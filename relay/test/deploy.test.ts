// The deployment configuration: a wrangler environment per relay of each circle, their bindings, variables and the
// secrets each one documents (wrangler.jsonc, README "Configuration").
import { describe, expect, it } from "vitest";
import raw from "../wrangler.jsonc?raw";
import readme from "../README.md?raw";
import { parseJsonc } from "../scripts/jsonc.ts";

interface Environment {
  name: string;
  vars: Record<string, string>;
  routes?: { pattern: string; custom_domain?: boolean }[];
  secrets: { required: string[] };
  assets: { directory: string; binding: string };
  d1_databases: { binding: string; database_name: string; database_id: string; migrations_dir: string }[];
}
const config = parseJsonc(raw) as { env: Record<string, Environment> };
const dinners = config.env["dinners"];
const dinnersRoman = config.env["dinners-roman"];
const luxury = config.env["luxury"];

describe("wrangler environments", () => {
  it("defines the founding circle's dinners and dinners-roman, and the Luxury Car Roll Up circle's luxury", () => {
    expect(Object.keys(config.env).sort()).toEqual(["dinners", "dinners-roman", "luxury"]);
    expect(dinners).toBeDefined();
    expect(dinnersRoman).toBeDefined();
  });

  it("gives each its own D1 database named for it, id the placeholder or the one its first deploy wrote, with the migrations", () => {
    for (const [name, e] of Object.entries(config.env)) {
      expect(e.d1_databases).toHaveLength(1);
      expect(e.d1_databases[0]).toMatchObject({ binding: "DB", database_name: `digestif-${name}`, migrations_dir: "migrations" });
      // scripts/deploy.sh replaces the all-zero placeholder with the created database's id, which is committed.
      expect(e.d1_databases[0]?.database_id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
      expect(e.assets).toMatchObject({ directory: "./app", binding: "ASSETS" });
    }
  });

  it("roots each relay in its circle and carries the protocol's default limits", () => {
    // The founding circle's two relays mirror one circle, so they name one founding dinner; a second
    // circle's relay names its own root.
    expect(dinnersRoman?.vars.CIRCLE_ROOT).toBe(dinners?.vars.CIRCLE_ROOT);
    expect(luxury?.vars.CIRCLE_ROOT).not.toBe(dinners?.vars.CIRCLE_ROOT);
    for (const e of Object.values(config.env)) {
      expect(e.vars.CIRCLE_ROOT).toMatch(/^sha256:[0-9a-f]{64}$/);
      expect(e.vars).toMatchObject({ MAX_ENVELOPE_BYTES: "65536", MAX_APPENDS_PER_DEVICE_PER_DAY: "500", MAX_PAGE_SIZE: "500", SKEW_SECONDS: "3600" });
      expect(e.vars.MAIL_FROM).toBeTruthy();
      expect(e.vars.RELAY_URL).toBeTruthy();
    }
  });

  it("judges admissions in every environment by the release-signers.json the build carries, never a configured set", () => {
    for (const e of Object.values(config.env)) expect(e.vars.RELEASE_SIGNERS).toBeUndefined();
  });

  it("makes dinners the mailer at dinners.digestif.io and the install script's host at digestif.io", () => {
    expect(dinners?.vars.MAILER).toBe("1");
    expect(dinners?.vars.RELAY_URL).toBe("https://dinners.digestif.io");
    expect(dinners?.routes).toEqual([
      { pattern: "dinners.digestif.io", custom_domain: true },
      { pattern: "digestif.io", custom_domain: true },
    ]);
    expect(dinners?.vars.INSTALL_SCRIPT_URL).toBe("https://github.com/digestif-ai/digestif/releases/latest/download/install.sh");
    expect(dinners?.vars.SITE_HOST).toBe("digestif.io");
    expect(dinners?.secrets.required).toEqual(["RELAY_SEALING_KEY", "RESEND_API_KEY"]);
  });

  it("keeps dinners-roman from mailing and from naming the mail key", () => {
    expect(dinnersRoman?.vars.MAILER).toBe("0");
    expect(dinnersRoman?.routes).toBeUndefined();
    expect(dinnersRoman?.vars.INSTALL_SCRIPT_URL).toBeUndefined();
    expect(JSON.stringify(dinnersRoman)).not.toContain("RESEND_API_KEY");
    expect(dinnersRoman?.secrets.required).toEqual(["RELAY_SEALING_KEY"]);
  });

  it("makes luxury its circle's mailer at luxury.digestif.io, never the install script's host", () => {
    expect(luxury?.vars.MAILER).toBe("1");
    expect(luxury?.vars.RELAY_URL).toBe("https://luxury.digestif.io");
    expect(luxury?.routes).toEqual([{ pattern: "luxury.digestif.io", custom_domain: true }]);
    expect(luxury?.vars.INSTALL_SCRIPT_URL).toBeUndefined();
    expect(luxury?.vars.SITE_HOST).toBeUndefined();
    expect(luxury?.secrets.required).toEqual(["RELAY_SEALING_KEY", "RESEND_API_KEY"]);
  });

  it("gives every environment its own rate-limit namespace", () => {
    const ids = Object.values(config.env).map((e) => (e as unknown as { ratelimits: { namespace_id: string }[] }).ratelimits[0]?.namespace_id);
    expect(new Set(ids).size).toBe(ids.length);
  });

  it("documents RELAY_SEALING_KEY for both and RESEND_API_KEY for the mailers in the README", () => {
    for (const e of Object.values(config.env)) expect(e.secrets.required).toContain("RELAY_SEALING_KEY");
    expect(readme).toContain("`RELAY_SEALING_KEY`");
    expect(readme).toContain("`RESEND_API_KEY`");
  });
});
