// The test circle: a throwaway founding dinner whose root hash a relay under test is configured with.
// Its seeds are public on purpose. It admits nothing but test keys and must never root a real circle.
import "./node-crypto.ts"; // installs the node:crypto SuiteCrypto: this module only runs on Node
import { readFileSync, writeFileSync } from "node:fs";
import { dinnerBody } from "./bodies.ts";
import { envelopeHash, signEnvelope, type SignedEnvelope } from "./envelope.ts";
import { Signer } from "./keys.ts";

export interface CircleFile {
  description: string;
  host_identity_seed: string;
  host_device_seed: string;
  root_hash: string;
  root: SignedEnvelope;
}

export const DEFAULT_CIRCLE_PATH = new URL("../fixtures/test-circle.json", import.meta.url);

export class TestCircle {
  readonly hostIdentity: Signer;
  readonly hostDevice: Signer;
  readonly root: SignedEnvelope;
  readonly rootHash: string;

  constructor(file: CircleFile) {
    this.hostIdentity = Signer.fromSeed(file.host_identity_seed);
    this.hostDevice = Signer.fromSeed(file.host_device_seed);
    this.root = file.root;
    this.rootHash = envelopeHash(file.root.envelope);
    if (this.rootHash !== file.root_hash) throw new Error(`root_hash ${file.root_hash} does not match the root envelope (${this.rootHash})`);
    if (file.root.envelope.author !== this.hostDevice.key) throw new Error("the root dinner is not authored by the host device seed");
  }

  static load(path: string | URL = DEFAULT_CIRCLE_PATH): TestCircle {
    return new TestCircle(JSON.parse(readFileSync(path, "utf8")) as CircleFile);
  }

  /** A fresh founding dinner with no guests: guests arrive in later dinners the cases write. */
  static create(label: string, relays: string[], createdAt = new Date()): CircleFile {
    const hostIdentity = Signer.random();
    const hostDevice = Signer.random();
    const root = signEnvelope(hostDevice, {
      kind: "dinner",
      body: dinnerBody(hostIdentity, label, [], relays, createdAt),
      seq: 1,
      epoch: 0,
      createdAt,
    });
    return {
      description:
        "A throwaway Digestif test circle for the conformance suite. Its seeds are public: never root a real circle with it.",
      host_identity_seed: hostIdentity.seedText,
      host_device_seed: hostDevice.seedText,
      root_hash: envelopeHash(root.envelope),
      root,
    };
  }

  static write(path: string, file: CircleFile): void {
    writeFileSync(path, `${JSON.stringify(file, null, 2)}\n`);
  }
}
