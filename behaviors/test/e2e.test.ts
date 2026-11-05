// End to end: two built nodes in one circle, through two fake relays, the read behavior on both.
//
// Needs the built `digestif`: it skips itself unless DIGESTIF_BIN names it, so `npm test` needs no
// binary. ci/build.sh runs it with the binary right after the node conformance cases:
//
//   DIGESTIF_BIN=node/_build/install/default/bin/digestif node --test behaviors/test/e2e.test.ts
//
// What it does (nothing under node/ is touched, and `digestif join` and `digestif setup`, which need a
// terminal, are not used):
//   - two relays from conformance/src/fake-relay.ts, one founding dinner, a dinner naming two guests;
//   - two data directories set up with `digestif init --root <hash> --relay <r1> --relay <r2>`, the
//     recovery phrase on stdin and the plain-file keystore (DIGESTIF_INSECURE_KEYSTORE_DIR), so no
//     system keychain is touched. Each phrase's identity key is derived here as docs/protocol.md says,
//     to sign the join the terminal flow would have signed, and the root, the dinner and both joins are
//     published to both relays. Both nodes are given both relays, not one each: a node reaches only the
//     relays in its own list (it adopts others from a relay message, which must name a public https
//     relay, and these are loopback http), so two nodes on disjoint relays would never see each other;
//   - `digestif run` on both nodes (a sync every 2 seconds, which also spawns the read behavior once a
//     node is Active), the read behavior set on both, a fake harness of the D5.3 kind (it answers one
//     line of JSON as the harness's result and runs no model): node B's answers a reply to a note
//     about Thursday and a flagged proposal to a note that says FLAG-ME, node A's answers nothing.
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { createHash, createHmac, pbkdf2Sync, randomBytes } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { localDay, readStateDir } from "../src/read.ts";

const bin = process.env["DIGESTIF_BIN"];
const here = import.meta.dirname;
const conformance = (name: string): Promise<unknown> => import(new URL(`../../conformance/src/${name}.ts`, import.meta.url).href);

// The little of the conformance suite this case uses, as the types the case relies on.
interface SignerLike {
  key: string;
}
interface SignedLike {
  envelope: { kind: string };
}
interface CircleLike {
  rootHash: string;
}
interface WorldLike {
  setup(): Promise<void>;
  dinner(names: string[]): Promise<{ name: string; invite: SignerLike; dinnerHash: string }[]>;
  publish(urls: string[], author: SignerLike, signed: SignedLike, options?: { unsigned?: boolean }): Promise<string>;
}
interface RelayLike {
  listen(): Promise<string>;
  close(): Promise<void>;
}

/** 24 BIP39 words for fresh entropy (docs/protocol.md, the recovery phrase). */
function newPhrase(): string {
  const words = readFileSync(join(here, "..", "src", "bip39-english.txt"), "utf8")
    .split("\n")
    .filter((w) => w !== "");
  assert.equal(words.length, 2048);
  const entropy = randomBytes(32);
  const bits = [...entropy, createHash("sha256").update(entropy).digest()[0]!].map((b) => b.toString(2).padStart(8, "0")).join("");
  return Array.from({ length: 24 }, (_, i) => words[parseInt(bits.slice(i * 11, i * 11 + 11), 2)]!).join(" ");
}

/** The identity signing seed of a phrase: HMAC-SHA512(key "digestif-v0 identity", the BIP39 seed)[0..32]. */
function identitySeed(phrase: string): Uint8Array {
  const seed = pbkdf2Sync(phrase, "mnemonic", 2048, 64, "sha512");
  return createHmac("sha512", "digestif-v0 identity").update(seed).digest().subarray(0, 32);
}

interface NodeDir {
  name: string;
  data: string;
  env: NodeJS.ProcessEnv;
  phrase: string;
  identity: string;
  device: string;
}

/** The harness: it logs nothing and runs no model; `answer` maps the message text to the one JSON line it returns. */
const harnessSource = (mode: "silent" | "bo") =>
  `#!${process.execPath}
const fs = require("fs");
const stdin = fs.readFileSync(0, "utf8");
let out = '{"outcome":"nothing"}';
if (${JSON.stringify(mode)} === "bo") {
  if (stdin.includes("FLAG-ME")) {
    out = JSON.stringify({ outcome: "propose", flag: true, kind: "intro", title: "Introduce Ann to Phong?", detail: "Ann asked for an introduction.", options: [{ id: "yes", label: "Yes", recommended: true }, { id: "no", label: "No" }], on_no_answer: "no" });
  } else if (stdin.includes("Thursday")) {
    out = '{"outcome":"reply","text":"Thursday works for me."}';
  }
}
console.log(JSON.stringify({ type: "result", subtype: "success", is_error: false, result: out }));
`;

test(
  "two nodes through two fake relays: a note on one is answered on the other within the budgets, and a flagged message raises one ask",
  { skip: bin === undefined ? "DIGESTIF_BIN is not set" : false, timeout: 600_000 }, // three waits of up to 150 s each, plus setup and cleanup
  async (t) => {
    const digestif = bin as string;
    const root = mkdtempSync(join(tmpdir(), "digestif-e2e-"));
    const daemons: ChildProcess[] = [];
    const relays: RelayLike[] = [];
    try {
      const { TestCircle } = (await conformance("circle")) as { TestCircle: { create(label: string, relays: string[]): unknown; new (file: unknown): CircleLike } };
      const { FakeRelay } = (await conformance("fake-relay")) as { FakeRelay: new (o: { root: string }) => RelayLike };
      const { World } = (await conformance("world")) as { World: new (c: CircleLike, urls: string[]) => WorldLike };
      const { Signer } = (await conformance("keys")) as { Signer: new (seed: Uint8Array) => SignerLike & { sign(d: string): string } };
      const { joinBody } = (await conformance("bodies")) as { joinBody(d: string, invite: unknown, identity: unknown, device: SignerLike): unknown };
      const { signEnvelope } = (await conformance("envelope")) as { signEnvelope(s: unknown, f: unknown): SignedLike };

      // The circle: the founding dinner, on both relays, and a dinner inviting the two members.
      const circle = new TestCircle(TestCircle.create("e2e", []));
      for (let i = 0; i < 2; i++) {
        const relay = new FakeRelay({ root: circle.rootHash });
        relays.push(relay);
      }
      const urls: string[] = [];
      for (const relay of relays) urls.push(await relay.listen());
      const world = new World(circle, urls);
      await world.setup();
      const invitations = await world.dinner(["Ann", "Bo"]);

      // The two nodes: init, then the join each phrase's identity signs here.
      const cli = (node: NodeDir, args: string[], stdin = "") =>
        new Promise<{ status: number | null; stdout: string; stderr: string }>((resolve) => {
          const p = spawn(digestif, [...args, "--data-dir", node.data], { env: node.env, stdio: ["pipe", "pipe", "pipe"] });
          let stdout = "";
          let stderr = "";
          p.stdout.on("data", (b: Buffer) => (stdout += b));
          p.stderr.on("data", (b: Buffer) => (stderr += b));
          p.once("close", (status) => resolve({ status, stdout, stderr }));
          p.stdin.end(stdin);
        });
      const ok = async (node: NodeDir, args: string[], stdin = "") => {
        const r = await cli(node, args, stdin);
        assert.equal(r.status, 0, `digestif ${args.join(" ")} (${node.name}) exited ${String(r.status)}: ${r.stderr}${r.stdout}`);
        return r.stdout;
      };
      const setup = async (name: string, phrase: string): Promise<NodeDir> => {
        const keystore = join(root, `${name}-keystore`);
        mkdirSync(keystore, { recursive: true });
        const node: NodeDir = { name, data: join(root, `${name}-data`), env: { ...process.env, DIGESTIF_INSECURE_KEYSTORE_DIR: keystore }, phrase, identity: "", device: "" };
        await ok(node, ["init", "--root", circle.rootHash, ...urls.flatMap((u) => ["--relay", u])], phrase);
        const keys = JSON.parse(await ok(node, ["keys"])) as { device_key: string };
        node.device = keys.device_key;
        node.identity = new Signer(identitySeed(phrase)).key;
        return node;
      };
      const ann = await setup("ann", newPhrase());
      const bo = await setup("bo", newPhrase());
      for (const [node, invitation] of [[ann, invitations[0]!], [bo, invitations[1]!]] as const) {
        const signed = signEnvelope(invitation.invite, {
          kind: "join",
          body: joinBody(invitation.dinnerHash, invitation.invite, new Signer(identitySeed(node.phrase)), { key: node.device }),
          seq: 1,
          epoch: 0,
        });
        await world.publish(urls, invitation.invite, signed, { unsigned: true });
      }
      for (const [node, agent] of [[ann, "Ada"], [bo, "Bea"]] as const) {
        await ok(node, ["sync"]);
        await ok(node, ["card", "--name", node === ann ? "Ann" : "Bo", "--agent-name", agent]);
        await ok(node, ["sync"]);
      }

      // The read behavior and its fake harness, set on both.
      const exe = join(root, "read");
      writeFileSync(exe, `#!/bin/sh\nexec "${process.execPath}" "${join(here, "..", "bin", "read.ts")}" "$@"\n`, { mode: 0o755 });
      for (const [node, mode] of [[ann, "silent"], [bo, "bo"]] as const) {
        const harness = join(root, `${node.name}-harness`);
        writeFileSync(harness, harnessSource(mode), { mode: 0o755 });
        mkdirSync(join(node.data, "behaviors", "nightly"), { recursive: true });
        writeFileSync(join(node.data, "behaviors", "nightly", "config.json"), JSON.stringify({ harness, agent: "claude_code" }));
        await ok(node, ["behavior", "set", "read", exe]);
      }

      // Both nodes run: a sync every 2 seconds, the send job, and the read behavior once Active.
      for (const node of [ann, bo]) {
        const log = join(root, `${node.name}-run.log`);
        const p = spawn(digestif, ["run", "--data-dir", node.data, "--interval", "2", "--ui-port", "0", "--no-self-update"], { env: node.env, stdio: ["ignore", "pipe", "pipe"] });
        p.stdout.on("data", (b: Buffer) => appendFileSync(log, b));
        p.stderr.on("data", (b: Buffer) => appendFileSync(log, b));
        daemons.push(p);
      }
      const logs = () =>
        [ann, bo].map((n) => `--- ${n.name}\n${existsSync(join(root, `${n.name}-run.log`)) ? readFileSync(join(root, `${n.name}-run.log`), "utf8") : ""}`).join("\n");
      const waitFor = async (what: string, done: () => boolean | Promise<boolean>) => {
        const until = Date.now() + 150_000;
        while (!(await done())) {
          if (Date.now() > until) assert.fail(`timed out waiting for ${what}\n${logs()}`);
          await new Promise((r) => setTimeout(r, 500));
        }
      };
      const readState = (node: NodeDir): { counters: Record<string, number>; flags: Record<string, number> } => {
        const file = join(readStateDir(node.data), "state.json");
        return existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : { counters: {}, flags: {} };
      };
      const approve = (node: NodeDir, text: string) => ok(node, ["note", "--approve", "--text", "-"], text);
      const askKeys = async () => (await ok(bo, ["asks"])).split("\n").filter((l) => l.startsWith("read-"));
      const questionsFrom = async (reader: NodeDir, author: string) =>
        (await ok(reader, ["log", "--kind", "question"])).split("\n").filter((l) => l.includes(author));

      const startDay = localDay(new Date());
      // Bo's first note makes Bo Active, so Bo's read behavior runs; then Ann's note about Thursday.
      await approve(bo, "Bo checking in: nothing to report yet.");
      await approve(ann, "Ann asks: is Thursday free for lunch?");
      await waitFor("Bo's reply to reach Ann through the relays", async () => (await questionsFrom(ann, bo.device)).length === 1);
      assert.equal(readState(bo).counters["outbound"], 1, "exactly one reply, counted as outbound");

      // A flagged message raises one ask; a second flag from the same sender the same day raises none.
      await approve(ann, "Ann: FLAG-ME please introduce me to Phong.");
      await waitFor("the flagged message's ask", async () => (await askKeys()).length === 1);
      // The read state's counters and flags reset when the local day changes, so a run that crosses
      // local midnight here would honor the second flag; that run proves nothing, so it is skipped.
      if (localDay(new Date()) !== startDay) return t.skip("the run crossed local midnight, which resets the flag budget");
      try {
        await approve(ann, "Ann: FLAG-ME again, introduce me to Andrey too.");
        await waitFor("the second flag to be refused as over budget", () => readState(bo).counters["flags_over_budget"] === 1);
        assert.equal((await askKeys()).length, 1, "the second flag raised no ask");
        assert.equal((await questionsFrom(ann, bo.device)).length, 1, "and no further reply was posted");

        // Within max_outbound 10, max_flags_per_sender 1 and max_agent_runs 30.
        const state = readState(bo);
        assert.equal(state.flags[ann.identity], 1);
        assert.ok((state.counters["outbound"] ?? 0) <= 10, "max_outbound");
        assert.ok((state.counters["agent_runs"] ?? 0) >= 3 && (state.counters["agent_runs"] ?? 0) <= 30, "max_agent_runs");
        assert.deepEqual(readState(ann).flags, {});
      } catch (e) {
        // Midnight can also pass while the second flag is waited for: the read run then loads a fresh
        // day, honors the flag, and the waits above fail. That is the reset, not a fault in the node.
        if (localDay(new Date()) !== startDay) return t.skip("the run crossed local midnight, which resets the flag budget");
        throw e;
      }
    } finally {
      // End each daemon and wait for it (SIGKILL after 10 seconds) before the directory goes, so a
      // process still writing under root cannot make the cleanup throw over the real failure.
      await Promise.all(
        daemons.map(
          (p) =>
            new Promise<void>((resolve) => {
              if (p.exitCode !== null || p.signalCode !== null) return resolve();
              const hard = setTimeout(() => p.kill("SIGKILL"), 10_000);
              p.once("exit", () => {
                clearTimeout(hard);
                resolve();
              });
              p.kill("SIGTERM");
            }),
        ),
      );
      for (const relay of relays) await relay.close();
      try {
        rmSync(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
      } catch {
        // a leftover temp directory is not a test failure
      }
    }
  },
);
