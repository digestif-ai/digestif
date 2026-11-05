#!/usr/bin/env node
// Prints a relay release bundle's bundle.json (docs/releases.md, Relay releases) from wrangler.jsonc:
// what a deploy of the bundle's module needs that the module does not carry, and nothing that
// belongs to one deployment. ci/relay-bundle.sh writes it into the bundle.
//
//   node scripts/bundle-json.ts [wrangler.jsonc]
//
// It holds the main module's name, the compatibility date and flags, the assets binding and how
// assets are served, and the NAMES of the bindings the Worker reads: the D1 binding, every var and
// every secret any deployment in wrangler.jsonc sets. No value of a var, no route, no database id
// and no secret is in it, so one bundle deploys to every relay unchanged, and a deploy keeps each
// deployment's own values (the deploy step's keep_bindings).
import { readFileSync } from "node:fs";
import path from "node:path";
import { parseJsonc } from "./jsonc.ts";

type Config = Record<string, unknown>;

interface BundleJson {
  format: "digestif-relay-bundle-v1";
  main_module: string;
  compatibility_date: string;
  compatibility_flags: string[];
  assets: { directory: string; binding: string; html_handling?: string; run_worker_first?: boolean };
  bindings: { d1: string[]; vars: string[]; secrets: string[] };
}

function record(value: unknown, what: string): Config {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error(`${what} is not an object`);
  return value as Config;
}

function str(value: unknown, what: string): string {
  if (typeof value !== "string" || value === "") throw new Error(`${what} is not a non-empty string`);
  return value;
}

/** The deployments a config describes: its top level and every environment, each read as wrangler reads it. */
function deployments(config: Config): Config[] {
  const envs = config.env === undefined ? {} : record(config.env, "env");
  return [config, ...Object.entries(envs).map(([name, env]) => record(env, `env.${name}`))];
}

function sorted(names: Iterable<string>): string[] {
  return [...new Set(names)].sort();
}

export function bundleJson(config: Config): BundleJson {
  const assets = record(config.assets, "assets");
  const flags = config.compatibility_flags ?? [];
  if (!Array.isArray(flags) || !flags.every((f) => typeof f === "string")) throw new Error("compatibility_flags is not a list of strings");
  const all = deployments(config);
  const d1 = all.flatMap((d) => (Array.isArray(d.d1_databases) ? d.d1_databases : []).map((db, i) => str(record(db, `d1_databases[${i}]`).binding, `d1_databases[${i}].binding`)));
  const vars = all.flatMap((d) => (d.vars === undefined ? [] : Object.keys(record(d.vars, "vars"))));
  const secrets = all.flatMap((d) => {
    const required = d.secrets === undefined ? [] : record(d.secrets, "secrets").required;
    return Array.isArray(required) ? required.map((s, i) => str(s, `secrets.required[${i}]`)) : [];
  });
  return {
    format: "digestif-relay-bundle-v1",
    main_module: `${path.basename(str(config.main, "main")).replace(/\.[cm]?[jt]s$/, "")}.js`,
    compatibility_date: str(config.compatibility_date, "compatibility_date"),
    compatibility_flags: flags,
    assets: {
      directory: "app",
      binding: str(assets.binding, "assets.binding"),
      ...(typeof assets.html_handling === "string" ? { html_handling: assets.html_handling } : {}),
      ...(typeof assets.run_worker_first === "boolean" ? { run_worker_first: assets.run_worker_first } : {}),
    },
    bindings: { d1: sorted(d1), vars: sorted(vars), secrets: sorted(secrets) },
  };
}

if (typeof process !== "undefined" && process.argv[1]?.endsWith("bundle-json.ts") === true) {
  const file = process.argv[2] ?? path.join(import.meta.dirname, "..", "wrangler.jsonc");
  console.log(JSON.stringify(bundleJson(record(parseJsonc(readFileSync(file, "utf8")), file)), null, 2));
}
