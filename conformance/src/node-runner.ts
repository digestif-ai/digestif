// How the suite drives a node: the node adapter contract (conformance/README.md, "Testing a node").
//
//   <node command> sync --home <empty dir> --device-seed-file <file> --relay <url> [--relay <url>...]
//
// The node starts from an empty home, signs its relay requests with the device key whose 32-byte
// Ed25519 seed (base64url) is in the file, syncs every relay in the order given, prints one JSON
// NodeState on stdout and exits 0.
import { execFile } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import type { Signer } from "./keys.ts";
import type { NodeState } from "./reference-node.ts";

const run = promisify(execFile);

export const REFERENCE_NODE = `${process.execPath} ${new URL("../bin/reference-node.ts", import.meta.url).pathname}`;

export class NodeRunner {
  readonly command: string[];

  constructor(command: string) {
    this.command = command.trim().split(/\s+/);
  }

  async sync(device: Signer, relays: string[]): Promise<NodeState> {
    const home = mkdtempSync(join(tmpdir(), "digestif-node-"));
    try {
      const seedFile = join(home, "device-seed");
      writeFileSync(seedFile, `${device.seedText}\n`, { mode: 0o600 });
      const nodeHome = join(home, "home");
      const [program, ...rest] = this.command;
      if (program === undefined) throw new Error("no node command");
      const args = [...rest, "sync", "--home", nodeHome, "--device-seed-file", seedFile, ...relays.flatMap((r) => ["--relay", r])];
      let stdout: string;
      try {
        ({ stdout } = await run(program, args, { timeout: 120_000, maxBuffer: 64 * 1024 * 1024 }));
      } catch (error) {
        const e = error as { code?: unknown; stderr?: string };
        throw new Error(`${this.command.join(" ")} sync exited ${String(e.code)}: ${(e.stderr ?? String(error)).slice(0, 2000)}`);
      }
      return normalize(JSON.parse(stdout) as NodeState);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  }
}

/** Sorts what the contract does not order, so states compare as text. The feed keeps its order. */
export function normalize(state: NodeState): NodeState {
  const cmp = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);
  return {
    epoch: state.epoch,
    keys: [...state.keys].map((k) => ({ key: k.key, role: k.role, identity: k.identity, revoked: k.revoked })).sort((a, b) => cmp(a.key, b.key)),
    feed: [...state.feed],
    faults: [...state.faults]
      .map((f) => ({ kind: f.kind, author: f.author, seq: f.seq, hashes: [...f.hashes].sort() }))
      .sort((a, b) => cmp(`${a.author}/${a.seq}`, `${b.author}/${b.seq}`)),
    gaps: [...state.gaps].map((g) => ({ author: g.author, missing: [...g.missing].sort((x, y) => x - y) })).sort((a, b) => cmp(a.author, b.author)),
  };
}
