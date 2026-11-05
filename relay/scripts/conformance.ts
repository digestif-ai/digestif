#!/usr/bin/env node
// Runs the conformance suite's relay cases against this Worker under `wrangler dev`: one instance
// per relay on a fresh local D1 with the migrations applied, rooted in the suite's test circle
// (`digestif-conformance circle show`). Exits with the suite's status: 1 when any case fails.
//
//   npm run conformance                      two instances, so the two-relay cases run too
//   npm run conformance -- --instances 1     one instance; the two-relay cases are skipped
//   npm run conformance -- --case relay.clock
//   npm run conformance -- --bundle DIR      every instance runs an unpacked relay release bundle
//                                            (ci/relay-bundle.sh) as it stands: its module, not
//                                            bundled again, its app/ and its migrations, so the
//                                            relay release build tests the bytes it packs
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { parseArgs } from "node:util";
import { parseJsonc } from "./jsonc.ts";

const relayDir = path.resolve(import.meta.dirname, "..");
const conformanceBin = path.resolve(relayDir, "..", "conformance", "bin", "digestif-conformance.ts");
const wrangler = path.resolve(relayDir, "node_modules", ".bin", "wrangler");

const { values } = parseArgs({
  options: {
    instances: { type: "string", default: "2" },
    port: { type: "string" },
    case: { type: "string", multiple: true },
    bundle: { type: "string" },
  },
});
const instances = Number(values.instances);
const firstPort = values.port === undefined ? undefined : Number(values.port);
if (!Number.isInteger(instances) || instances < 1) throw new Error("--instances must be a positive integer");
if (firstPort !== undefined && (!Number.isInteger(firstPort) || firstPort < 1)) throw new Error("--port must be a port number");
const bundle = values.bundle === undefined ? undefined : path.resolve(values.bundle);

/** A port nothing on 127.0.0.1 listens on now: the OS picks it for a listener that closes at once. */
function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      server.close(() => (typeof address === "object" && address !== null ? resolve(address.port) : reject(new Error("no port"))));
    });
  });
}

/** --port N runs on N, N+1, ...; without it each instance gets a free port, so a busy 8787 is no failure. */
async function ports(): Promise<number[]> {
  const out: number[] = [];
  for (let i = 0; i < instances; i++) {
    if (firstPort !== undefined) out.push(firstPort + i);
    else {
      let p = await freePort();
      while (out.includes(p)) p = await freePort();
      out.push(p);
    }
  }
  return out;
}

const env = { ...process.env, WRANGLER_SEND_METRICS: "false", CI: "1" };

function circleRoot(): string {
  const shown = spawnSync(process.execPath, [conformanceBin, "circle", "show"], { encoding: "utf8", env });
  if (shown.status !== 0) throw new Error(`circle show failed: ${shown.stderr}`);
  const { root_hash } = JSON.parse(shown.stdout) as { root_hash: string };
  return root_hash;
}

interface Instance {
  url: string;
  state: string;
  process: ChildProcess;
}

/**
 * Every instance after the first is stamped with a relay release, as the release build stamps the
 * Worker (src/version.ts), and the first is not, so relay.circle.relay-version reads both shapes.
 * A bundle's module (--bundle) is run as it stands, so every instance reports the stamp it was
 * built with.
 */
const STAMP = "0.0.1";

/**
 * The configuration an unpacked bundle runs under: wrangler.jsonc's top level (no environment) for
 * the local vars and the D1 binding, and everything else from the bundle: its module, not bundled
 * again, its bundle.json's compatibility settings, its app/ and its migrations. Every path is
 * absolute, since wrangler resolves them against the configuration's own directory.
 */
function bundleConfig(dir: string, state: string): string {
  const top = parseJsonc(readFileSync(path.join(relayDir, "wrangler.jsonc"), "utf8")) as Record<string, unknown>;
  const { env: _env, $schema: _schema, ...rest } = top;
  const described = JSON.parse(readFileSync(path.join(dir, "bundle.json"), "utf8")) as {
    main_module: string;
    compatibility_date: string;
    compatibility_flags: string[];
    assets: Record<string, unknown>;
  };
  const databases = rest.d1_databases as Array<Record<string, unknown>>;
  const config = {
    ...rest,
    main: path.join(dir, "worker", described.main_module),
    no_bundle: true,
    compatibility_date: described.compatibility_date,
    compatibility_flags: described.compatibility_flags,
    assets: { ...described.assets, directory: path.join(dir, String(described.assets.directory)) },
    d1_databases: databases.map((d) => ({ ...d, migrations_dir: path.join(dir, "migrations") })),
  };
  const file = path.join(state, "wrangler.json");
  writeFileSync(file, JSON.stringify(config, null, 2));
  return file;
}

/** The configuration every wrangler call of an instance names: wrangler.jsonc, or the bundle's. */
function configArgs(state: string): string[] {
  return bundle === undefined ? [] : ["--config", bundleConfig(bundle, state)];
}

/** How the Worker is stamped: a bundle's module already is; the source is stamped or not by instance. */
function stampArgs(stamped: boolean): string[] {
  return bundle === undefined && stamped ? ["--define", `RELAY_VERSION_STAMP:${JSON.stringify(STAMP)}`] : [];
}

function start(root: string, port: number, stamped: boolean): Instance {
  const state = mkdtempSync(path.join(tmpdir(), `digestif-relay-${port}-`));
  const config = configArgs(state);
  const migrated = spawnSync(wrangler, ["d1", "migrations", "apply", "digestif-relay", "--local", "--persist-to", state, ...config], { cwd: relayDir, encoding: "utf8", env });
  if (migrated.status !== 0) throw new Error(`migrations failed on ${state}:\n${migrated.stdout}\n${migrated.stderr}`);
  const child = spawn(
    wrangler,
    ["dev", ...config, ...stampArgs(stamped), "--port", String(port), "--ip", "127.0.0.1", "--persist-to", state, "--var", `CIRCLE_ROOT:${root}`, "--show-interactive-dev-session=false", "--log-level", "warn"],
    { cwd: relayDir, env, stdio: ["ignore", "pipe", "pipe"] },
  );
  child.stdout?.on("data", (chunk: Buffer) => process.stderr.write(`[relay ${port}] ${chunk.toString()}`));
  child.stderr?.on("data", (chunk: Buffer) => process.stderr.write(`[relay ${port}] ${chunk.toString()}`));
  return { url: `http://127.0.0.1:${port}`, state, process: child };
}

/** Ready when GET /v0/circle answers at all: 401 not_admitted, since the request is unsigned. */
async function waitReady(instance: Instance, timeoutMs = 90_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (instance.process.exitCode !== null) throw new Error(`wrangler dev on ${instance.url} exited with ${instance.process.exitCode}`);
    try {
      const response = await fetch(`${instance.url}/v0/circle`);
      if (response.status === 401) return;
    } catch {
      // not listening yet
    }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error(`wrangler dev on ${instance.url} did not come up in ${timeoutMs / 1000}s`);
}

async function stop(instance: Instance): Promise<void> {
  if (instance.process.exitCode === null) {
    instance.process.kill("SIGTERM");
    await new Promise<void>((resolve) => {
      const timer = setTimeout(() => {
        instance.process.kill("SIGKILL");
        resolve();
      }, 5_000);
      instance.process.once("exit", () => {
        clearTimeout(timer);
        resolve();
      });
    });
  }
  rmSync(instance.state, { recursive: true, force: true });
}

const root = circleRoot();
const started: Instance[] = [];
let status: number;
try {
  for (const port of await ports()) started.push(start(root, port, started.length > 0));
  await Promise.all(started.map((instance) => waitReady(instance)));
  const args = [conformanceBin, "relay", ...started.flatMap((instance) => ["--url", instance.url]), ...(values.case ?? []).flatMap((c) => ["--case", c])];
  console.error(`running: digestif-conformance ${args.slice(1).join(" ")}`);
  const run = spawnSync(process.execPath, args, { stdio: "inherit", env });
  status = run.status ?? 1;
} finally {
  await Promise.all(started.map(stop));
}
process.exit(status);
