// The deny layer in plain JavaScript (docs/design.md, Guarding what goes out), for the phone web
// app: the member's deny list and the built-in detectors node/web/deny.ml and node/web/financial.ml
// run before the node signs anything, so the phone refuses exactly the text the machine refuses. It
// runs unchanged in a browser and Node 20+, and needs WebCrypto only for SHA-256 (Base58Check and
// the BIP39 checksum). ../test/deny_cases.json holds the cases both sides run.
//
// The OCaml side matches bytes with ocaml-re, so this side matches the text's UTF-8 bytes, one
// character per byte, and spells every class the way ocaml-re reads it: `\s` is space and \t to \r,
// a word character is ocaml-re's Latin-1 one, `.` is anything but \n, `$` is the end of the text. A
// trip names the rule that tripped, never the text that tripped it.

import { BIP39_ENGLISH } from "./bip39-english.mjs";

const subtle = globalThis.crypto.subtle;

/** The text as its UTF-8 bytes, one character per byte. */
export function bytesOf(text) {
  let s = "";
  for (const b of new TextEncoder().encode(text)) s += String.fromCharCode(b);
  return s;
}

const toBytes = (s) => Uint8Array.from(s, (c) => c.charCodeAt(0));
const sha256 = async (bytes) => new Uint8Array(await subtle.digest("SHA-256", bytes));

// ocaml-re's character sets (Cset.space, Cset.cword), in JavaScript class syntax.
const SPACE = String.raw`\t-\r `;
const WORD = String.raw`0-9A-Z_a-z\xaa\xb5\xba\xc0-\xd6\xd8-\xf6\xf8-\xff`;
const BOUNDARY = `(?:(?<![${WORD}])(?=[${WORD}])|(?<=[${WORD}])(?![${WORD}]))`;

/**
 * A Perl-style pattern as ocaml-re's Re.Perl reads it (node/web/deny.ml compiles every pattern with
 * it), rewritten for JavaScript's RegExp over UTF-8 bytes, or undefined when it does not translate.
 */
export function translatePattern(p) {
  let out = "";
  let i = 0;
  let inClass = false;
  const n = p.length;
  while (i < n) {
    const c = p[i];
    if (inClass) {
      if (c === "]") {
        inClass = false;
        out += c;
        i += 1;
      } else if (c === "\\") {
        const d = p[i + 1];
        if (d === undefined) return undefined;
        const cls = { w: WORD, s: SPACE, d: "0-9", b: "\\x08", n: "\\n", r: "\\r", t: "\\t" }[d];
        if (cls !== undefined) out += cls;
        else if (/[A-Za-z0-9]/.test(d)) return undefined;
        else out += "\\" + d;
        i += 2;
      } else if (c === "[" && p[i + 1] === ":") {
        return undefined;
      } else {
        out += c === "/" ? "\\/" : c;
        i += 1;
      }
      continue;
    }
    if (c === "[") {
      inClass = true;
      out += c;
      i += 1;
      if (p[i] === "^") {
        out += "^";
        i += 1;
      }
      if (p[i] === "]") {
        out += "\\]";
        i += 1;
      }
      continue;
    }
    if (c === ".") {
      out += "[^\\n]";
      i += 1;
      continue;
    }
    if (c === "$") {
      out += "(?![^])";
      i += 1;
      continue;
    }
    if (c === "(" && p[i + 1] === "?") {
      if (p[i + 2] === ":") {
        out += "(?:";
        i += 3;
      } else if (p[i + 2] === "#") {
        const close = p.indexOf(")", i);
        if (close < 0) return undefined;
        i = close + 1;
      } else if (p[i + 2] === "<" && p[i + 3] !== "=" && p[i + 3] !== "!") {
        out += "(?:";
        const close = p.indexOf(">", i);
        if (close < 0) return undefined;
        i = close + 1;
      } else return undefined;
      continue;
    }
    if (c === "\\") {
      const d = p[i + 1];
      if (d === undefined) return undefined;
      i += 2;
      switch (d) {
        case "w":
          out += `[${WORD}]`;
          break;
        case "W":
          out += `[^${WORD}]`;
          break;
        case "s":
          out += `[${SPACE}]`;
          break;
        case "S":
          out += `[^${SPACE}]`;
          break;
        case "d":
          out += "[0-9]";
          break;
        case "D":
          out += "[^0-9]";
          break;
        case "b":
          out += BOUNDARY;
          break;
        case "B":
          out += `(?:(?<=[${WORD}])(?=[${WORD}])|(?<![${WORD}])(?![${WORD}]))`;
          break;
        case "A":
          out += "^";
          break;
        case "Z":
          out += "(?=\\n?(?![^]))";
          break;
        case "z":
          out += "(?![^])";
          break;
        case "e":
          out += "\\x1b";
          break;
        case "f":
          out += "\\f";
          break;
        case "n":
          out += "\\n";
          break;
        case "r":
          out += "\\r";
          break;
        case "t":
          out += "\\t";
          break;
        case "Q": {
          const end = p.indexOf("\\E", i);
          const quoted = end < 0 ? p.slice(i) : p.slice(i, end);
          out += quoted.replace(/[.*+?^${}()|[\]\\/-]/g, "\\$&");
          i = end < 0 ? n : end + 2;
          break;
        }
        default:
          if (/[A-Za-z0-9]/.test(d)) return undefined;
          out += "\\" + d;
      }
      continue;
    }
    out += c === "/" ? "\\/" : c;
    i += 1;
  }
  return inClass ? undefined : out;
}

/** A pattern compiled for [bytesOf] text, case-insensitively, as deny.ml's `rx` compiles it. */
function rx(pattern, flags = "i") {
  const source = translatePattern(pattern);
  if (source === undefined) throw new Error(`untranslatable pattern ${pattern}`);
  return new RegExp(source, flags);
}

const any = (patterns) => {
  const res = patterns.map((p) => rx(p));
  return (text) => res.some((re) => re.test(text));
};

/** Every match of [re] (a global expression), in order, never overlapping. */
const all = (re, text) => [...text.matchAll(re)];

// --- financial.ml --------------------------------------------------------------------------------

const isDigit = (c) => c >= "0" && c <= "9";
const isAlnum = (c) => isDigit(c) || (c >= "a" && c <= "z") || (c >= "A" && c <= "Z");

/** Maximal runs of characters satisfying [f], with their start offsets. */
function runs(f, text) {
  const out = [];
  let i = 0;
  while (i < text.length) {
    if (!f(text[i])) {
      i += 1;
      continue;
    }
    let j = i;
    while (j < text.length && f(text[j])) j += 1;
    out.push([i, text.slice(i, j)]);
    i = j;
  }
  return out;
}

/** Luhn (ISO/IEC 7812). */
function luhn(d) {
  let sum = 0;
  for (let i = 0; i < d.length; i += 1) {
    let v = d.charCodeAt(d.length - 1 - i) - 48;
    if (i % 2 === 1) v = v * 2 > 9 ? v * 2 - 9 : v * 2;
    sum += v;
  }
  return d.length > 0 && sum % 10 === 0;
}

/** Payment card numbers: Luhn-valid runs of 13 to 19 digits in whole groups, starting 3 to 6 or 22 to 27. */
function card(text) {
  return all(/[0-9]+(?:[ -][0-9]+)*/g, text).some((m) => {
    const start = m.index;
    const stop = start + m[0].length;
    const before = start > 0 ? text[start - 1] : undefined;
    const after = stop < text.length ? text[stop] : undefined;
    const groups = m[0].split(/[ -]/);
    const k = groups.length;
    for (let i = 0; i < k; i += 1)
      for (let j = i; j < k; j += 1) {
        const d = groups.slice(i, j + 1).join("");
        const len = d.length;
        const prefix = (d[0] >= "3" && d[0] <= "6") || (d[0] === "2" && len > 1 && d[1] >= "2" && d[1] <= "7");
        const edge = (i > 0 || before !== "-") && (j < k - 1 || after !== "-");
        if (edge && len >= 13 && len <= 19 && prefix && luhn(d)) return true;
      }
    return false;
  });
}

/** ISO 13616 mod 97. */
function ibanValid(s) {
  const n = s.length;
  if (n < 15 || n > 34) return false;
  const r = s.slice(4) + s.slice(0, 4);
  let rem = 0;
  for (const c of r) {
    let piece;
    if (isDigit(c)) piece = c;
    else if (c >= "A" && c <= "Z") piece = String(c.charCodeAt(0) - 55);
    else return false;
    for (const d of piece) rem = (rem * 10 + d.charCodeAt(0) - 48) % 97;
  }
  return rem === 1;
}

function iban(text) {
  return all(/[A-Z][A-Z][0-9][0-9](?:[ -]?[A-Z0-9])+/g, text).some((g) => {
    const start = g.index;
    if (start > 0 && isAlnum(text[start - 1])) return false;
    const m = g[0];
    const n = m.length;
    for (let e = n; e >= 15; e -= 1) {
      if ((e === n || m[e] === " " || m[e] === "-") && ibanValid(m.slice(0, e).replace(/[ -]/g, ""))) return true;
    }
    return false;
  });
}

/** ABA routing number: nine digits, weights 3-7-1, in a Federal Reserve range. */
function abaValid(d) {
  if (d.length !== 9) return false;
  const v = (i) => d.charCodeAt(i) - 48;
  const p = v(0) * 10 + v(1);
  return (
    (p <= 12 || (p >= 21 && p <= 32) || (p >= 61 && p <= 72) || p === 80) &&
    (3 * (v(0) + v(3) + v(6)) + 7 * (v(1) + v(4) + v(7)) + v(2) + v(5) + v(8)) % 10 === 0
  );
}

/** A routing number followed within forty characters on the same line by an account of 6 to 17 digits. */
function routingAndAccount(text) {
  const r = runs(isDigit, text);
  for (let i = 0; i + 1 < r.length; i += 1) {
    const [s1, routing] = r[i];
    const [s2, account] = r[i + 1];
    const gap = text.slice(s1 + routing.length, s2);
    if (abaValid(routing) && gap.length >= 1 && gap.length <= 40 && !gap.includes("\n") && account.length >= 6 && account.length <= 17)
      return true;
  }
  return false;
}

const BASE58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

/** Base58Check: the payload, when the last four bytes are the first four of its double SHA-256. */
async function base58checkPayload(s) {
  let value = 0n;
  for (const c of s) {
    const v = BASE58.indexOf(c);
    if (v < 0) return undefined;
    value = value * 58n + BigInt(v);
  }
  const digits = [];
  while (value > 0n) {
    digits.unshift(Number(value & 0xffn));
    value >>= 8n;
  }
  let zeros = 0;
  while (zeros < s.length && s[zeros] === "1") zeros += 1;
  const b = Uint8Array.from([...new Array(zeros).fill(0), ...digits]);
  if (b.length < 5) return undefined;
  const payload = b.slice(0, b.length - 4);
  const check = await sha256(await sha256(payload));
  for (let i = 0; i < 4; i += 1) if (check[i] !== b[b.length - 4 + i]) return undefined;
  return payload;
}

const BECH32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

/** BIP173 bech32 or BIP350 bech32m: one case throughout, and the checksum over the human part. */
function bech32Valid(s) {
  const lower = s.toLowerCase();
  if (s !== lower && s !== s.toUpperCase()) return false;
  const sep = lower.lastIndexOf("1");
  if (sep < 1 || lower.length - sep - 1 < 6) return false;
  const hrp = lower.slice(0, sep);
  const data = [...lower.slice(sep + 1)].map((c) => BECH32.indexOf(c));
  if (data.includes(-1)) return false;
  const gen = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  let chk = 1;
  const step = (v) => {
    const top = chk >>> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ v;
    for (let i = 0; i < 5; i += 1) if ((top >>> i) & 1) chk ^= gen[i];
  };
  for (const c of hrp) step(c.charCodeAt(0) >>> 5);
  step(0);
  for (const c of hrp) step(c.charCodeAt(0) & 31);
  for (const v of data) step(v);
  return chk === 1 || chk === 0x2bc830a3;
}

const ETHEREUM = /^0x[0-9a-fA-F]{40}$/;
const BECH32_ADDRESS = /^(bc|tb|ltc|tltc)1[ac-hj-np-z02-9]{8,87}$/i;

/** Crypto wallet addresses and keys, each a whole word: Base58Check payloads, bech32 and bech32m, Ethereum. */
async function wallet(text) {
  for (const [, w] of runs(isAlnum, text)) {
    if (ETHEREUM.test(w) || (BECH32_ADDRESS.test(w) && bech32Valid(w))) return true;
    if (w.length >= 25 && w.length <= 112 && [...w].every((c) => BASE58.includes(c))) {
      const p = await base58checkPayload(w);
      if (p !== undefined && [21, 33, 34, 78].includes(p.length)) return true;
    }
  }
  return false;
}

const BIP39_INDEX = new Map(BIP39_ENGLISH.map((w, i) => [w, i]));

/** Whether the words (each a BIP39 word) carry a valid checksum, as node/core/phrase.ml validates. */
async function bip39Valid(words) {
  const bits = words.map((w) => BIP39_INDEX.get(w).toString(2).padStart(11, "0")).join("");
  const ent = (words.length * 11 * 32) / 33;
  const entropy = new Uint8Array(ent / 8);
  for (let i = 0; i < entropy.length; i += 1) entropy[i] = parseInt(bits.slice(i * 8, i * 8 + 8), 2);
  const digest = await sha256(entropy);
  const cs = [...digest].map((b) => b.toString(2).padStart(8, "0")).join("").slice(0, ent / 32);
  return bits.slice(ent) === cs;
}

/** Recovery phrases: 12, 15, 18, 21 or 24 consecutive BIP39 English words whose checksum holds. */
async function recoveryPhrase(text) {
  const words = runs((c) => c >= "a" && c <= "z", asciiLower(text)).map(([, w]) => w);
  const windowValid = async (run) => {
    for (const n of [24, 21, 18, 15, 12])
      for (let i = 0; i + n <= run.length; i += 1) if (await bip39Valid(run.slice(i, i + n))) return true;
    return false;
  };
  let run = [];
  for (const w of [...words, undefined]) {
    if (w !== undefined && BIP39_INDEX.has(w)) {
      run.push(w);
      continue;
    }
    if (run.length >= 12 && (await windowValid(run))) return true;
    run = [];
  }
  return false;
}

async function bankAccount(text) {
  return iban(text) || routingAndAccount(text);
}

// --- deny.ml -------------------------------------------------------------------------------------

/** Shannon entropy in bits per character. */
function entropy(s) {
  const counts = new Map();
  for (const c of s) counts.set(c, (counts.get(c) ?? 0) + 1);
  let h = 0;
  for (const k of counts.values()) {
    const p = k / s.length;
    h -= p * Math.log2(p);
  }
  return h;
}

/** A long token that mixes letters and digits and is close to random. */
function highEntropy(text) {
  return all(/[A-Za-z0-9+/=_-]{32,}/g, text).some(([t]) => /[a-z]/.test(t) && /[A-Z]/.test(t) && /[0-9]/.test(t) && entropy(t) > 4.2);
}

/** The built-in detectors, in the order deny.ml runs them, by the name a trip reports. */
export const DETECTORS = [
  {
    name: "Key and token shapes",
    test: any([
      String.raw`sk-[A-Za-z0-9_-]{16,}`,
      String.raw`\bAKIA[0-9A-Z]{16}\b`,
      String.raw`\bgh[pousr]_[A-Za-z0-9]{30,}`,
      String.raw`\bxox[abprs]-[A-Za-z0-9-]{10,}`,
      String.raw`\bbearer\s+[A-Za-z0-9._~+/-]{20,}`,
      String.raw`\bAIza[0-9A-Za-z_-]{35}\b`,
    ]),
  },
  { name: "Private keys", test: any([String.raw`-----BEGIN [A-Z ]*PRIVATE KEY-----`]) },
  { name: "Connection strings", test: any([String.raw`[a-z][a-z0-9+.-]*://[^\s:/@]+:[^\s@/]+@`]) },
  { name: "Payment card numbers", test: card },
  { name: "Bank account numbers", test: bankAccount },
  { name: "Crypto wallets", test: wallet },
  { name: "Recovery phrases", test: recoveryPhrase },
  { name: "High-entropy strings", test: highEntropy },
];

function asciiLower(s) {
  return s.replace(/[A-Z]/g, (c) => String.fromCharCode(c.charCodeAt(0) + 32));
}

const wordChar = (c) => c !== undefined && /[A-Za-z0-9_]/.test(c);

/** A name or id matches as a whole word, case-insensitively; a domain matches anywhere. */
function wholeWord(needle, hay) {
  needle = asciiLower(needle);
  hay = asciiLower(hay);
  if (needle.length === 0) return false;
  for (let i = hay.indexOf(needle); i >= 0; i = hay.indexOf(needle, i + 1))
    if (!wordChar(hay[i - 1]) && !wordChar(hay[i + needle.length])) return true;
  return false;
}

/**
 * Whether one deny list entry trips on [text] (bytesOf'd), or "untranslatable" for a pattern this
 * side cannot run as the machine does, which refuses rather than passes.
 */
function entryTrips(e, text) {
  switch (e.kind) {
    case "domain":
      return e.value.length > 0 && asciiLower(text).includes(asciiLower(bytesOf(e.value)));
    case "pattern": {
      const source = translatePattern(bytesOf(e.value));
      if (source === undefined) return "untranslatable";
      try {
        return new RegExp(source, "i").test(text);
      } catch {
        return "untranslatable";
      }
    }
    default:
      return wholeWord(bytesOf(e.value), text);
  }
}

/**
 * The deny layer over one outbound text, as deny.ml's `check` runs it: the member's deny list first,
 * a name entry never tripping on one of [allowed] (the circle's member and agent names), then every
 * detector. Undefined when the text passes, else the rule that tripped: "deny: <kind>" or
 * "detector: <name>". A pattern this side cannot run as the machine does refuses with "deny: pattern".
 *
 * @param {string} text
 * @param {{ kind: string, value: string }[]} entries
 * @param {string[]} allowed
 * @returns {Promise<string | undefined>}
 */
export async function denyCheck(text, entries, allowed = []) {
  const t = bytesOf(text);
  const circle = new Set(allowed.map((a) => asciiLower(bytesOf(a))));
  for (const e of entries) {
    if (e.kind === "name" && circle.has(asciiLower(bytesOf(e.value)))) continue;
    if (entryTrips(e, t) !== false) return "deny: " + e.kind;
  }
  for (const d of DETECTORS) if (await d.test(t)) return "detector: " + d.name;
  return undefined;
}
