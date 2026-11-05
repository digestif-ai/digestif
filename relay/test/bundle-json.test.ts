// A relay release bundle's bundle.json (scripts/bundle-json.ts): what a deploy of the bundle needs
// beside the module, and nothing that belongs to one deployment.
import { describe, expect, it } from "vitest";
import raw from "../wrangler.jsonc?raw";
import readme from "../README.md?raw";
import { parseJsonc } from "../scripts/jsonc.ts";
import { bundleJson } from "../scripts/bundle-json.ts";

const config = parseJsonc(raw) as Record<string, unknown>;
const described = bundleJson(config);

describe("bundle.json", () => {
  it("names the module wrangler writes for src/index.ts, and the top level's compatibility settings", () => {
    expect(described.main_module).toBe("index.js");
    expect(described.compatibility_date).toBe(config.compatibility_date);
    expect(described.compatibility_flags).toEqual(config.compatibility_flags);
    expect(described.assets).toEqual({ directory: "app", binding: "ASSETS", html_handling: "none", run_worker_first: true });
  });

  it("names every binding the README's Configuration documents, from every deployment", () => {
    expect(described.bindings.d1).toEqual(["DB"]);
    for (const name of [...described.bindings.vars, ...described.bindings.secrets]) expect(readme).toContain(`| \`${name}\` |`);
    expect(described.bindings.vars).toContain("RELAY_URL");
    expect(described.bindings.vars).toContain("SITE_HOST");
    expect(described.bindings.secrets).toEqual(["RELAY_SEALING_KEY", "RESEND_API_KEY"]);
  });

  it("carries no per-deployment value: no var's value, no route, no database id, no environment name", () => {
    const text = JSON.stringify(described);
    expect(text).not.toContain("sha256:");
    expect(text).not.toContain("digestif.io");
    expect(text).not.toContain("database_id");
    expect(text).not.toContain("dinners");
    expect(text).not.toContain("routes");
  });

  it("refuses a configuration with no main module", () => {
    const { main: _main, ...rest } = config;
    expect(() => bundleJson(rest)).toThrow(/main/);
  });
});
