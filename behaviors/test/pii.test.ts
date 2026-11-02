// The PII detectors: positive and negative cases per detector, with made-up values (reserved
// example domains, documentation phone ranges, published test card numbers, checksum-valid ids
// built for the test), the allow list, and the screen command's verdict and exit codes.
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { abaValid, base58checkPayload, bech32Valid, bip39Valid, cpfValid, ibanValid, luhn, nhsValid, verhoeffValid } from "../src/checksums.ts";
import { bankAccount, cryptoWallet, email, recoveryPhrase, governmentId, maskAllowed, paymentCard, phone, screenPii, streetAddress, type Detector } from "../src/pii.ts";

function trips(d: Detector, cases: Record<string, string | undefined>) {
  for (const [text, expected] of Object.entries(cases)) {
    assert.equal(d.test(text), expected, `"${text}" -> ${expected ?? "clean"}`);
  }
}

test("email addresses", () => {
  trips(email, {
    "Wrote to ada.lovelace@example.com about the parser": "pii: email address",
    "cc first+tag@mail.example.co.uk": "pii: email address",
    "the @mention syntax, and user@localhost, and a@b": undefined,
    "Worked on: the fetcher; Learned: retries; Stuck on: nothing.": undefined,
  });
});

test("phone numbers, international and North American", () => {
  trips(phone, {
    "Call +44 20 7946 0958 tomorrow": "pii: phone number (international)",
    "+1 (202) 555-0143": "pii: phone number (international)",
    "+33.1.99.00.12.34": "pii: phone number (international)",
    "(202) 555-0143 or 202-555-0143": "pii: phone number (North American)",
    "1-800-555-0199": "pii: phone number (North American)",
    "202.555.0143": "pii: phone number (North American)",
    "+3 more": undefined,
    "version 1.2.3 released 2026-10-29 at 12:30:45": undefined,
    "the 2025550143 id": undefined,
    "IQ-2024 and 555-0100 and 100-200-3000": undefined,
    "a 15-digit run +1234567890123456 is not E.164": undefined,
  });
});

test("street addresses", () => {
  trips(streetAddress, {
    "Met at 10 Downing Street": "pii: street address",
    "Ship to 1600 Pennsylvania Avenue NW, Washington": "pii: street address",
    "221B Baker St.": "pii: street address",
    "4 Rue de la Paix is not an English shape": undefined,
    "3 easy ways to cut the build time": undefined,
    "Took 2 Big Steps forward": undefined,
    "Fixed 12 flaky tests and 3 Drive letters": undefined,
  });
});

test("government ids, one per shape in the documented list", () => {
  trips(governmentId, {
    "SSN 123-45-6789": "pii: government id (US SSN)",
    "SSN 123 45 6789": "pii: government id (US SSN)",
    "ITIN 912-75-1234": "pii: government id (US ITIN)",
    "SIN 046-454-286": "pii: government id (Canadian SIN)",
    "NI AB 12 34 56 C": "pii: government id (UK National Insurance number)",
    "NI AB123456C": "pii: government id (UK National Insurance number)",
    "NHS 943 476 5919": "pii: government id (UK NHS number)",
    "DNI 12345678Z": "pii: government id (Spanish DNI or NIE)",
    "NIE X1234567L and 12345678-Z": "pii: government id (Spanish DNI or NIE)",
    "CPF 123.456.789-09": "pii: government id (Brazilian CPF)",
    "CF RSSMRA85T10A562S": "pii: government id (Italian codice fiscale)",
    "Aadhaar 2345 6789 0124": "pii: government id (Indian Aadhaar)",
    "NIR 1 85 05 78 006 084 91": "pii: government id (French NIR)",
    // Shapes without their check, excluded areas, and runs of bare digits.
    "123456789 and 000-12-3456 and 666-12-3456 and 123-00-4567": undefined,
    "SIN 046-454-287": undefined,
    "NHS 943 476 5918": undefined,
    "DNI 12345678A and NIE X1234567M": undefined,
    "order 12345678 Zebra and 12345678Zed": undefined,
    "CPF 123.456.789-00 and 111.111.111-11": undefined,
    "CF RSSMRA85T10A562T": undefined,
    "Aadhaar 2345 6789 0125 and 1234 5678 9012": undefined,
    "NIR 1 85 05 78 006 084 36": undefined,
    "NI GB 12 34 56 C and QQ123456C": undefined,
    "build 20261029-123456 and ticket IQ-2024": undefined,
  });
});

test("payment card numbers: Luhn-valid trips, Luhn-invalid does not", () => {
  assert.equal(luhn("4111111111111111"), true);
  assert.equal(luhn("4111111111111112"), false);
  trips(paymentCard, {
    "card 4111111111111111": "pii: payment card number",
    "card 4111 1111 1111 1111": "pii: payment card number",
    "card 4111-1111-1111-1111": "pii: payment card number",
    "card 5500 0000 0000 0004": "pii: payment card number",
    "amex 3782 822463 10005": "pii: payment card number",
    "mastercard 2223 0000 4841 0010": "pii: payment card number",
    "mastercard 2223000048410010": "pii: payment card number",
    "discover 6011111111111117": "pii: payment card number",
    "card 4111111111111112": undefined,
    "card 4111 1111 1111 1112": undefined,
    "epoch 1761700000000 and 1234567812345670": undefined,
    "mastercard 2223 0000 4841 0011 and 2123 0000 4841 0017": undefined,
    "a 20-digit run 41111111111111111111": undefined,
  });
});

test("bank account numbers: IBAN with checksum, US routing and account pairs", () => {
  assert.equal(ibanValid("GB82WEST12345698765432"), true);
  assert.equal(ibanValid("GB82WEST12345698765433"), false);
  assert.equal(abaValid("123456780"), true);
  assert.equal(abaValid("123456781"), false);
  trips(bankAccount, {
    "IBAN GB82 WEST 1234 5698 7654 32": "pii: bank account number (IBAN)",
    "IBAN DE89370400440532013000": "pii: bank account number (IBAN)",
    "IBAN FR76 3000 6000 0112 3456 7890 189": "pii: bank account number (IBAN)",
    "routing 123456780, account 9876543210": "pii: bank account number (US routing and account)",
    "123456780 / 00123456": "pii: bank account number (US routing and account)",
    "IBAN GB82 WEST 1234 5698 7654 33": undefined,
    "postcode EN17 1AB and ticket AB12 CDEF GHIJ": undefined,
    "routing 123456780 alone": undefined,
    "routing 123456781, account 9876543210": undefined,
    "account 9876543210 then routing 123456780": undefined,
  });
});

test("crypto wallet addresses and keys: each format's checksum, and Ethereum's shape", () => {
  assert.equal(base58checkPayload("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")?.length, 21);
  assert.equal(base58checkPayload("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNb"), undefined);
  assert.equal(bech32Valid("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"), true);
  assert.equal(bech32Valid("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5"), false);
  assert.equal(bech32Valid("bc1qW508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"), false, "mixed case");
  trips(cryptoWallet, {
    "send it to 1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa": "pii: crypto wallet address or key (Base58Check)",
    "P2SH 3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy": "pii: crypto wallet address or key (Base58Check)",
    "WIF 5HueCGU8rMjxEXxiPuD5BDku4MkFqeZyd4dZ1jvhTVqvbTLvyTJ": "pii: crypto wallet address or key (Base58Check)",
    "xpub661MyMwAqRbcFtXgS5sYJABqqG9YLmC4Q1Rdap9gSE8NqtwybGhePY2gZ29ESFjqJoCu1Rupje8YtGqsefD265TMg7usUDFdp6W1EGMcet8":
      "pii: crypto wallet address or key (Base58Check)",
    "segwit BC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4": "pii: crypto wallet address or key (bech32)",
    "taproot bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0": "pii: crypto wallet address or key (bech32)",
    "eth 0xde0B295669a9FD93d5F28D9Ec85E40f4cb697BAe": "pii: crypto wallet address or key (Ethereum)",
    "a typo 1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNb": undefined,
    "segwit bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5": undefined,
    "commit de0b295669a9fd93d5f28d9ec85e40f4cb697bae and a 0x1f flag": undefined,
    "the word ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijk": undefined,
    "Worked on the wallet app's send screen; paid $1,200 for the bank feed": undefined,
  });
});

test("recovery phrases: BIP39 words with a valid checksum, however they are laid out", () => {
  const twelve = "abandon ".repeat(11) + "about";
  const twentyFour = "void come effort suffer camp survey warrior heavy shoot primary clutch crush open amazing screen patrol group space point ten exist slush involve unfold";
  assert.equal(bip39Valid(twelve.split(" ")), true);
  assert.equal(bip39Valid("abandon ".repeat(12).trim().split(" ")), false, "checksum");
  assert.equal(bip39Valid(twentyFour.split(" ")), true);
  trips(recoveryPhrase, {
    [`my phrase is ${twelve}, keep it safe`]: "pii: recovery phrase",
    [twentyFour.toUpperCase()]: "pii: recovery phrase",
    [twelve.split(" ").map((w, i) => `${i + 1}. ${w}`).join("\n")]: "pii: recovery phrase",
    [`seed: ${twelve.split(" ").join(", ")}`]: "pii: recovery phrase",
    [`the void ${twentyFour} and more`]: "pii: recovery phrase",
    ["abandon ".repeat(12)]: undefined,
    ["abandon ".repeat(10) + "about"]: undefined,
    [twelve.replace("about", "zzz")]: undefined,
    ["Worked on: the fetcher's retry logic, the docs build and a cleaner release script. Learned: a polite backoff beats a fixed delay."]: undefined,
  });
});

test("the BIP39 list is the node's, word for word", () => {
  const here = import.meta.dirname;
  assert.equal(readFileSync(join(here, "..", "src", "bip39-english.txt"), "utf8"), readFileSync(join(here, "..", "..", "node", "core", "bip39_english.txt"), "utf8"));
});

test("checksums on their own", () => {
  assert.equal(nhsValid("9434765919"), true);
  assert.equal(cpfValid("12345678909"), true);
  assert.equal(verhoeffValid("234567890124"), true);
  assert.equal(luhn(""), false);
  assert.equal(luhn("12a4"), false);
  assert.equal(ibanValid("GB82"), false);
});

test("screenPii: a clean note passes, a trip names the rule and never the text", () => {
  assert.deepEqual(screenPii("Worked on: the fetcher's retry. Learned: backoff. Stuck on: nothing."), { ok: true });
  const verdict = screenPii("Worked on: onboarding; mailed ada.lovelace@example.com the brief.");
  assert.deepEqual(verdict, { ok: false, rule: "pii: email address" });
  assert.equal(JSON.stringify(verdict).includes("example.com"), false);
  // The first detector in order wins when several would trip.
  assert.deepEqual(screenPii("card 4111 1111 1111 1111, SSN 123-45-6789"), { ok: false, rule: "pii: government id (US SSN)" });
});

test("the circle's member and agent names are allowed; the member's own details are not", () => {
  const allowed = ["Mike Bryzek", "Athena", "Roman Cherkasov", "AB123456C"];
  assert.deepEqual(screenPii("Talked with Mike Bryzek; Athena (Mike's agent) replied.", allowed), { ok: true });
  // An agent whose name has the shape of an id trips without the list and passes with it.
  assert.deepEqual(screenPii("AB123456C posted a note", []), { ok: false, rule: "pii: government id (UK National Insurance number)" });
  assert.deepEqual(screenPii("AB123456C posted a note", allowed), { ok: true });
  assert.deepEqual(screenPii("ab123456c posted a note", allowed), { ok: true });
  // The name is a whole word: a different id that contains it still trips.
  assert.deepEqual(screenPii("NI AB123456CD vs AB 12 34 56 C", allowed), { ok: false, rule: "pii: government id (UK National Insurance number)" });
  // Masking leaves a space, so digits either side of a name never run together.
  assert.equal(maskAllowed("4111 Athena 1111 1111 1111", ["Athena"]), "4111        1111 1111 1111");
  // The member's own details are not exempt: their name is allowed, their email is not.
  assert.deepEqual(screenPii("Roman Cherkasov <roman@example.org> wrote", allowed), { ok: false, rule: "pii: email address" });
  // An allowed name inside an address is still an address: the email detector reads the text unmasked.
  for (const note of ["athena@example.com replied", "mail mike@example.com", "cc bryzek.mike@example.com"]) {
    assert.deepEqual(screenPii(note, [...allowed, "Mike"]), { ok: false, rule: "pii: email address" }, note);
  }
  assert.equal(maskAllowed("nothing", []), "nothing");
  assert.equal(maskAllowed("a (paren) name", ["(paren)"]), "a         name");
});

test("the screen command: a JSON verdict, exit 0 or 3, and the allow list", async () => {
  const run = promisify(execFile);
  const screen = (note: string, args: string[] = []) => {
    const child = run(process.execPath, ["bin/screen.ts", ...args]);
    child.child.stdin!.end(note);
    return child;
  };
  const clean = await screen("Worked on: the retry.\nLearned: backoff.\nStuck on: nothing.\n");
  assert.equal(clean.stdout, '{"ok":true}\n');
  await assert.rejects(screen("Stuck on: 221B Baker Street\n"), (e: { code: number; stdout: string }) => {
    assert.equal(e.code, 3);
    assert.equal(e.stdout, '{"ok":false,"rule":"pii: street address"}\n');
    return true;
  });
  const allowed = await screen("AB123456C posted\n", ["--allow", "AB123456C", "--allow", "Athena"]);
  assert.equal(allowed.stdout, '{"ok":true}\n');
  await assert.rejects(run(process.execPath, ["bin/screen.ts", "--bogus"]), (e: { code: number }) => {
    assert.equal(e.code, 2);
    return true;
  });
});
