// The deployment configuration: two wrangler environments, their bindings, variables and the
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

describe("wrangler environments", () => {
  it("defines exactly dinners and dinners-roman", () => {
    expect(Object.keys(config.env).sort()).toEqual(["dinners", "dinners-roman"]);
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

  it("roots both in one circle and carries the protocol's default limits", () => {
    // Both relays mirror the same circle, so they name one founding dinner.
    expect(dinners?.vars.CIRCLE_ROOT).toMatch(/^sha256:[0-9a-f]{64}$/);
    for (const e of Object.values(config.env)) {
      expect(e.vars.CIRCLE_ROOT).toBe(dinners?.vars.CIRCLE_ROOT);
      expect(e.vars).toMatchObject({ MAX_ENVELOPE_BYTES: "65536", MAX_APPENDS_PER_DEVICE_PER_DAY: "500", MAX_PAGE_SIZE: "500", SKEW_SECONDS: "3600" });
      expect(e.vars.MAIL_FROM).toBeTruthy();
      expect(e.vars.RELAY_URL).toBeTruthy();
    }
  });

  it("makes dinners the mailer at dinners.digestif.io", () => {
    expect(dinners?.vars.MAILER).toBe("1");
    expect(dinners?.vars.RELAY_URL).toBe("https://dinners.digestif.io");
    expect(dinners?.routes).toEqual([{ pattern: "dinners.digestif.io", custom_domain: true }]);
    expect(dinners?.secrets.required).toEqual(["RELAY_SEALING_KEY", "RESEND_API_KEY"]);
  });

  it("keeps dinners-roman from mailing and from naming the mail key", () => {
    expect(dinnersRoman?.vars.MAILER).toBe("0");
    expect(dinnersRoman?.routes).toBeUndefined();
    expect(JSON.stringify(dinnersRoman)).not.toContain("RESEND_API_KEY");
    expect(dinnersRoman?.secrets.required).toEqual(["RELAY_SEALING_KEY"]);
  });

  it("documents RELAY_SEALING_KEY for both and RESEND_API_KEY for dinners only in the README", () => {
    for (const e of Object.values(config.env)) expect(e.secrets.required).toContain("RELAY_SEALING_KEY");
    expect(readme).toContain("`RELAY_SEALING_KEY`");
    expect(readme).toContain("`RESEND_API_KEY`");
  });
});
