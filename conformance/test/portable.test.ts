// The modules a Worker relay imports (fold.ts and everything it reaches) carry no Node built-in and no
// `Buffer`, and take every signature and hash from the installed SuiteCrypto (src/crypto.ts).
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { installCrypto, suiteCrypto, type SuiteCrypto } from "../src/crypto.ts";
import { b64url, fromB64url } from "../src/encoding.ts";
import { Signer, verifySignature } from "../src/keys.ts";
import { nodeCrypto } from "../src/node-crypto.ts";

const src = join(dirname(fileURLToPath(import.meta.url)), "..", "src");

/** Every module fold.ts reaches through relative imports, fold.ts included. */
function foldGraph(): Map<string, string> {
  const seen = new Map<string, string>();
  const visit = (file: string) => {
    if (seen.has(file)) return;
    const text = readFileSync(join(src, file), "utf8");
    seen.set(file, text);
    for (const [, spec] of text.matchAll(/^import\s+(?:[^"']*\s+from\s+)?["']([^"']+)["']/gm)) {
      if (spec!.startsWith("./")) visit(spec!.slice(2));
    }
  };
  visit("fold.ts");
  return seen;
}

test("fold.ts and everything it imports use no Node built-in and no Buffer", () => {
  const graph = foldGraph();
  assert.deepEqual([...graph.keys()].sort(), ["crypto.ts", "encoding.ts", "envelope.ts", "fold.ts", "keys.ts"]);
  for (const [file, text] of graph) {
    const code = text.replace(/\/\/.*$/gm, "").replace(/\/\*[\s\S]*?\*\//g, "");
    assert.doesNotMatch(code, /["']node:/, `${file} imports a Node built-in`);
    assert.doesNotMatch(code, /\bBuffer\b/, `${file} uses Buffer`);
    assert.doesNotMatch(code, /\bprocess\./, `${file} uses process`);
  }
});

test("importing fold.ts installs no crypto; the host's installCrypto is what supplies it", () => {
  const script = `
    await import(${JSON.stringify(join(src, "fold.ts"))});
    const { suiteCrypto } = await import(${JSON.stringify(join(src, "crypto.ts"))});
    try { suiteCrypto(); console.log("installed"); } catch (e) { console.log(String(e.message).startsWith("no SuiteCrypto installed") ? "absent" : e.message); }
  `;
  const out = execFileSync(process.execPath, ["--input-type=module", "-e", script], { encoding: "utf8" });
  assert.equal(out.trim(), "absent");
});

test("b64url and fromB64url agree with Node's base64url at every length", () => {
  for (let n = 0; n <= 70; n++) {
    const bytes = randomBytes(n);
    const text = b64url(bytes);
    assert.equal(text, bytes.toString("base64url"));
    assert.deepEqual(Buffer.from(fromB64url(text)), bytes);
  }
  assert.deepEqual(Buffer.from(fromB64url("+/8=")), Buffer.from("+/8=", "base64"));
  assert.throws(() => fromB64url("ab!c"));
  assert.throws(() => fromB64url("abcde"));
});

test("signing, verifying and hashing go through the installed SuiteCrypto", () => {
  const calls: string[] = [];
  const counting: SuiteCrypto = {
    ed25519PublicKey: (seed) => (calls.push("publicKey"), nodeCrypto.ed25519PublicKey(seed)),
    ed25519Sign: (seed, data) => (calls.push("sign"), nodeCrypto.ed25519Sign(seed, data)),
    ed25519Verify: (key, data, sig) => (calls.push("verify"), nodeCrypto.ed25519Verify(key, data, sig)),
    sha256: (data) => (calls.push("sha256"), nodeCrypto.sha256(data)),
  };
  const before = suiteCrypto();
  installCrypto(counting);
  try {
    const signer = Signer.random();
    const signature = signer.sign("hello");
    assert.equal(verifySignature(signer.key, "hello", signature), true);
    assert.equal(verifySignature(signer.key, "hellO", signature), false);
    assert.equal(verifySignature("ed25519:not*base64", "hello", signature), false);
    assert.deepEqual(calls, ["publicKey", "sign", "verify", "verify"]);
  } finally {
    installCrypto(before);
  }
});
