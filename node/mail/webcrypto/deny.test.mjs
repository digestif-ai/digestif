import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { BIP39_ENGLISH } from "./bip39-english.mjs";
import { denyCheck, translatePattern } from "./deny.mjs";

const read = (env, path) => readFileSync(process.env[env] ?? new URL(path, import.meta.url), "utf8");
const { cases } = JSON.parse(read("DIGESTIF_DENY_CASES", "../test/deny_cases.json"));

test("the machine's cases: the phone refuses the same text by the same rule", async () => {
  assert.ok(cases.length > 50);
  for (const c of cases) assert.equal((await denyCheck(c.text, c.entries, c.allowed)) ?? null, c.rule, c.name);
});

test("the wordlist is the node's", () => {
  assert.deepEqual(BIP39_ENGLISH, read("DIGESTIF_BIP39_ENGLISH", "../../core/bip39_english.txt").split("\n").filter((w) => w !== ""));
});

test("a pattern the phone cannot run as the machine does refuses rather than passes", async () => {
  assert.equal(translatePattern(String.raw`a\x41`), undefined);
  assert.equal(await denyCheck("anything", [{ kind: "pattern", value: String.raw`\G` }]), "deny: pattern");
  assert.equal(await denyCheck("anything", [{ kind: "pattern", value: "(?=x)" }]), "deny: pattern");
});

test("a quoted run is literal", async () => {
  assert.equal(await denyCheck("cost a.b+c", [{ kind: "pattern", value: String.raw`\Qa.b+c\E` }]), "deny: pattern");
  assert.equal(await denyCheck("cost aXb+c", [{ kind: "pattern", value: String.raw`\Qa.b+c\E` }]), undefined);
});
