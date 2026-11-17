// A signed document holding a member twice reads one way to the node (the first) and another to
// JSON.parse (the last), so the relay's readers refuse it (src/strict-json.ts).
import { test } from "node:test";
import assert from "node:assert/strict";
import { signedDocumentOf } from "../src/admission.ts";
import { b64url } from "../src/encoding.ts";
import { duplicateMember, parseUnique } from "../src/strict-json.ts";

test("finds a member twice at any depth, compared decoded", () => {
  assert.equal(duplicateMember('{"a":1,"b":2}'), undefined);
  assert.equal(duplicateMember('{"a":1,"a":2}'), "a");
  assert.equal(duplicateMember('{"x":{"a":1,"b":{"c":[{"d":1,"d":2}]}}}'), "d");
  assert.equal(duplicateMember('{"a":1,"\\u0061":2}'), "a");
  // Values, array items and members of sibling objects are not names of the same object.
  assert.equal(duplicateMember('{"a":"a","b":["a","a"],"c":[{"a":1},{"a":2}],"d":"{\\"a\\":1,\\"a\\":2}"}'), undefined);
  assert.equal(duplicateMember('{"a":{},"b":[],"c":{"a":{}}}'), undefined);
});

test("parseUnique names the member and passes a document holding each once", () => {
  assert.deepEqual(parseUnique('{"a":1}', "doc"), { a: 1 });
  assert.throws(() => parseUnique('{"a":1,"a":2}', "doc"), /doc holds member "a" twice/);
  assert.throws(() => parseUnique("{", "doc"));
});

test("signedDocumentOf refuses an admission holding invite_key twice", () => {
  const admission = (extra: string) =>
    `{"format":"digestif-admission-v0","circle":"sha256:root","role":"member","invite_key":"ed25519:shown"${extra}}`;
  const body = (doc: string) => ({ document: b64url(new TextEncoder().encode(doc)), signatures: [] });
  assert.notEqual(signedDocumentOf(body(admission(""))), undefined);
  assert.equal(signedDocumentOf(body(admission(',"invite_key":"ed25519:admitted"'))), undefined);
});
