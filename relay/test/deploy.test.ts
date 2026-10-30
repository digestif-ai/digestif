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
const relay1 = config.env["relay-1"];
const relay2 = config.env["relay-2"];

describe("wrangler environments", () => {
  it("defines exactly relay-1 and relay-2", () => {
    expect(Object.keys(config.env).sort()).toEqual(["relay-1", "relay-2"]);
    expect(relay1).toBeDefined();
    expect(relay2).toBeDefined();
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

  it("leaves the root hash empty and carries the protocol's default limits", () => {
    for (const e of Object.values(config.env)) {
      expect(e.vars.CIRCLE_ROOT).toBe("");
      expect(e.vars).toMatchObject({ MAX_ENVELOPE_BYTES: "65536", MAX_APPENDS_PER_DEVICE_PER_DAY: "500", MAX_PAGE_SIZE: "500", SKEW_SECONDS: "3600" });
      expect(e.vars.MAIL_FROM).toBeTruthy();
      expect(e.vars.RELAY_URL).toBeTruthy();
    }
  });

  it("makes relay-1 the mailer at relay1.digestif.io", () => {
    expect(relay1?.vars.MAILER).toBe("1");
    expect(relay1?.vars.RELAY_URL).toBe("https://relay1.digestif.io");
    expect(relay1?.routes).toEqual([{ pattern: "relay1.digestif.io", custom_domain: true }]);
    expect(relay1?.secrets.required).toEqual(["RELAY_SEALING_KEY", "RESEND_API_KEY"]);
  });

  it("keeps relay-2 from mailing and from naming the mail key", () => {
    expect(relay2?.vars.MAILER).toBe("0");
    expect(relay2?.routes).toBeUndefined();
    expect(JSON.stringify(relay2)).not.toContain("RESEND_API_KEY");
    expect(relay2?.secrets.required).toEqual(["RELAY_SEALING_KEY"]);
  });

  it("documents RELAY_SEALING_KEY for both and RESEND_API_KEY for relay-1 only in the README", () => {
    for (const e of Object.values(config.env)) expect(e.secrets.required).toContain("RELAY_SEALING_KEY");
    expect(readme).toContain("`RELAY_SEALING_KEY`");
    expect(readme).toContain("`RESEND_API_KEY`");
  });
});
