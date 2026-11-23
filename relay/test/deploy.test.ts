// The deployment configuration: two wrangler environments, their bindings, variables and the
// secrets each one documents (wrangler.jsonc, README "Configuration").
import { describe, expect, it } from "vitest";
import raw from "../wrangler.jsonc?raw";
import readme from "../README.md?raw";
import { parseJsonc } from "../scripts/jsonc.ts";

interface Environment {
  name: string;
  keep_vars?: boolean;
  vars: Record<string, string>;
  routes?: { pattern: string; custom_domain?: boolean }[];
  secrets: { required: string[] };
  assets: { directory: string; binding: string };
  durable_objects: { bindings: { name: string; class_name: string }[] };
  d1_databases: { binding: string; database_name: string; database_id: string; migrations_dir: string }[];
}
const config = parseJsonc(raw) as { keep_vars?: boolean; env: Record<string, Environment> };
const dinners = config.env["dinners"];
const dinnersRoman = config.env["dinners-roman"];

describe("wrangler environments", () => {
  it("defines exactly dinners and dinners-roman", () => {
    expect(Object.keys(config.env).sort()).toEqual(["dinners", "dinners-roman"]);
    expect(dinners).toBeDefined();
    expect(dinnersRoman).toBeDefined();
  });

  it("keeps the variables a deployment holds, HOME_ROOT above all, and moves each home circle into its store", () => {
    expect(config.keep_vars).toBe(true);
    for (const [name, e] of Object.entries(config.env)) {
      expect(e.keep_vars, name).toBe(true);
      // HOME_ROOT is the operator's, written by `digestif circle found --relay`, never a file's.
      expect(e.vars["HOME_ROOT"], name).toBeUndefined();
      expect(e.vars["MOVE_ROWS_PER_DAY"], name).toBeUndefined();
    }
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

  it("binds each to the circles' store class the top level binds, with no migrations of its own", () => {
    const top = parseJsonc(raw) as { durable_objects: unknown; migrations: unknown };
    for (const e of Object.values(config.env)) {
      expect(e.durable_objects).toEqual(top.durable_objects);
      expect(e).not.toHaveProperty("migrations");
    }
    expect(top.migrations).toEqual([{ tag: "v1", new_sqlite_classes: ["CircleStore"] }]);
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

  it("judges admissions in every environment by the release-signers.json the build carries, never a configured set", () => {
    for (const e of Object.values(config.env)) expect(e.vars.RELEASE_SIGNERS).toBeUndefined();
  });

  it("names no INSTALL_SCRIPT_URL: the relay renders install.sh from the signed manifest (src/install.ts)", () => {
    expect(raw).not.toContain("INSTALL_SCRIPT_URL");
  });

  it("makes dinners the mailer at dinners.digestif.io and the install script's host at digestif.io", () => {
    expect(dinners?.vars.MAILER).toBe("1");
    expect(dinners?.vars.RELAY_URL).toBe("https://dinners.digestif.io");
    expect(dinners?.routes).toEqual([
      { pattern: "dinners.digestif.io", custom_domain: true },
      { pattern: "digestif.io", custom_domain: true },
    ]);
    expect(dinners?.vars.SITE_HOST).toBe("digestif.io");
    expect(dinners?.secrets.required).toEqual(["RELAY_SEALING_KEY", "RESEND_API_KEY"]);
  });

  it("keeps dinners-roman from mailing and from naming the mail key", () => {
    expect(dinnersRoman?.vars.MAILER).toBe("0");
    expect(dinnersRoman?.routes).toBeUndefined();
    expect(dinnersRoman?.vars.SITE_HOST).toBeUndefined();
    expect(JSON.stringify(dinnersRoman)).not.toContain("RESEND_API_KEY");
    expect(dinnersRoman?.secrets.required).toEqual(["RELAY_SEALING_KEY"]);
  });

  it("documents RELAY_SEALING_KEY for both and RESEND_API_KEY for dinners only in the README", () => {
    for (const e of Object.values(config.env)) expect(e.secrets.required).toContain("RELAY_SEALING_KEY");
    expect(readme).toContain("`RELAY_SEALING_KEY`");
    expect(readme).toContain("`RESEND_API_KEY`");
  });
});
