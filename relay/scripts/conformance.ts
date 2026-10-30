#!/usr/bin/env node
// Runs the conformance suite's relay cases against this Worker under `wrangler dev`: one instance
// per relay on a fresh local D1 with the migrations applied, rooted in the suite's test circle
// (`digestif-conformance circle show`). Exits with the suite's status: 1 when any case fails.
//
//   npm run conformance                      two instances, so the two-relay cases run too
//   npm run conformance -- --instances 1     one instance; the two-relay cases are skipped
//   npm run conformance -- --case relay.clock
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { parseArgs } from "node:util";

const relayDir = path.resolve(import.meta.dirname, "..");
const conformanceBin = path.resolve(relayDir, "..", "conformance", "bin", "digestif-conformance.ts");
const wrangler = path.resolve(relayDir, "node_modules", ".bin", "wrangler");

const { values } = parseArgs({
  options: {
    instances: { type: "string", default: "2" },
    port: { type: "string", default: "8787" },
    case: { type: "string", multiple: true },
  },
});
const instances = Number(values.instances);
const firstPort = Number(values.port);
if (!Number.isInteger(instances) || instances < 1) throw new Error("--instances must be a positive integer");
if (!Number.isInteger(firstPort) || firstPort < 1) throw new Error("--port must be a port number");

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

function start(root: string, port: number): Instance {
  const state = mkdtempSync(path.join(tmpdir(), `digestif-relay-${port}-`));
  const migrated = spawnSync(wrangler, ["d1", "migrations", "apply", "digestif-relay", "--local", "--persist-to", state], { cwd: relayDir, encoding: "utf8", env });
  if (migrated.status !== 0) throw new Error(`migrations failed on ${state}:\n${migrated.stdout}\n${migrated.stderr}`);
  const child = spawn(
    wrangler,
    ["dev", "--port", String(port), "--ip", "127.0.0.1", "--persist-to", state, "--var", `CIRCLE_ROOT:${root}`, "--show-interactive-dev-session=false", "--log-level", "warn"],
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
let status = 1;
try {
  for (let i = 0; i < instances; i++) started.push(start(root, firstPort + i));
  await Promise.all(started.map((instance) => waitReady(instance)));
  const args = [conformanceBin, "relay", ...started.flatMap((instance) => ["--url", instance.url]), ...(values.case ?? []).flatMap((c) => ["--case", c])];
  console.error(`running: digestif-conformance ${args.slice(1).join(" ")}`);
  const run = spawnSync(process.execPath, args, { stdio: "inherit", env });
  status = run.status ?? 1;
} finally {
  await Promise.all(started.map(stop));
}
process.exit(status);
