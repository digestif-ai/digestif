// The PII half of the deny layer (docs/design.md, Guarding what goes out): built-in detectors for
// email addresses, phone numbers, street addresses, government ids, payment card numbers, bank
// account numbers, crypto wallet addresses and keys, and recovery phrases, the companions of the secret detectors in node/web/deny.ml. Code, not a model:
// every detector is a shape, and where the id carries a check digit the detector verifies it, so
// a number that merely looks like a card is let through unless it is also Luhn-valid.
//
// A trip names the rule, never the text that tripped it. A member's own details are not exempt.
// The circle's member and agent names are masked before the detectors run, so a name that happens
// to look like an id shape does not refuse every note that greets its owner.

import {
  abaValid,
  base58checkPayload,
  bech32Valid,
  bip39Valid,
  codiceFiscaleValid,
  cpfValid,
  dniValid,
  ibanValid,
  isBip39Word,
  luhn,
  nhsValid,
  nirValid,
  verhoeffValid,
} from "./checksums.ts";

export interface Detector {
  /** The rule a trip names: "pii: …". */
  name: string;
  description: string;
  /** The shape that tripped, as a rule name, or undefined when the text is clean. */
  test(text: string): string | undefined;
}

type Shape = { name: string; pattern: RegExp; valid?: (match: RegExpExecArray) => boolean };

/** The detector trips on the first shape whose pattern matches and whose check passes. */
function shapes(name: string, description: string, list: Shape[]): Detector {
  const compiled = list.map((shape) => ({
    ...shape,
    pattern: new RegExp(shape.pattern.source, shape.pattern.flags.includes("g") ? shape.pattern.flags : shape.pattern.flags + "g"),
  }));
  return {
    name,
    description,
    test(text) {
      for (const shape of compiled) {
        for (const m of text.matchAll(shape.pattern)) {
          if (shape.valid === undefined || shape.valid(m)) {
            return shape.name === "" ? name : `${name} (${shape.name})`;
          }
        }
      }
      return undefined;
    },
  };
}

const digitsOf = (s: string) => s.replace(/\D/g, "");

// Email addresses: a local part, an @, a dotted host with a letters-only top level. A bare host
// without a dot (user@localhost) is not an address.
export const email = shapes("pii: email address", "Email addresses", [
  { name: "", pattern: /[A-Za-z0-9._%+-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*\.[A-Za-z]{2,}/ },
]);

// Phone numbers. International: a plus, a country code and 8 to 15 digits in all (E.164), in
// groups separated by a space, dot, dash or parentheses. North American: ten digits as
// area-exchange-line with separators between the groups, the area code 2 to 9, with or without a
// leading 1. A bare run of ten digits is not a phone number: it is far more often an id.
export const phone = shapes("pii: phone number", "Phone numbers, international and North American", [
  {
    name: "international",
    pattern: /(?<![\w+.-])\+\d{1,3}(?:[\s.-]?\(?\d{1,4}\)?){1,6}(?![\d])/,
    valid: (m) => {
      const n = digitsOf(m[0]).length;
      return n >= 8 && n <= 15;
    },
  },
  { name: "North American", pattern: /(?<![\w.-])(?:\+?1[\s.-]?)?\(?[2-9]\d{2}\)?[\s.-]\d{3}[\s.-]\d{4}(?![\w-])/ },
]);

const STREET_TYPES = [
  "Street", "St", "Avenue", "Ave", "Road", "Rd", "Boulevard", "Blvd", "Lane", "Ln", "Drive", "Dr",
  "Court", "Ct", "Way", "Place", "Pl", "Terrace", "Ter", "Circle", "Cir", "Highway", "Hwy", "Parkway",
  "Pkwy", "Square", "Sq", "Trail", "Trl", "Alley", "Crescent", "Cres", "Close", "Gardens", "Gdns",
  "Row", "Loop", "Plaza", "Plz", "Broadway", "Esplanade", "Promenade", "Quay", "Walk", "Grove",
];
const streetType = STREET_TYPES.flatMap((t) => [t, t.toUpperCase(), t.toLowerCase()]).join("|");

// Street addresses: a number (221B, 1600), one to four capitalised name words, and a street-type
// word, with an optional trailing period. "10 Downing Street", "1600 Pennsylvania Ave NW".
export const streetAddress = shapes("pii: street address", "Street addresses: a number, a name and a street type", [
  { name: "", pattern: new RegExp(String.raw`\b\d{1,6}[A-Za-z]?\s+(?:[A-Z][A-Za-z'’.-]*\s+){1,4}(?:${streetType})\b\.?`) },
]);

// Government ids. The list, each a shape with the check its issuer defines where there is one:
//   US SSN (AAA-GG-SSSS with the dashes or spaces; areas 000, 666 and 9xx excluded, groups 00 and
//     0000 excluded), US ITIN (9xx-7x-xxxx), Canadian SIN (3-3-3 digits, Luhn), UK National
//     Insurance number (two letters, six digits, A to D), UK NHS number (3-3-4 digits, mod 11),
//     Spanish DNI and NIE (eight digits and a check letter, or X/Y/Z, seven digits and the letter,
//     the letter joined or after a dash, never a space: "12345678 Zebra" is a count and a word),
//     Brazilian CPF (###.###.###-##, two check digits), Italian codice fiscale (sixteen characters,
//     check character), Indian Aadhaar (4-4-4 digits, Verhoeff), French NIR (fifteen digits with
//     the key).
//   Not detected: ids that are a bare run of digits with no separators or letters (Dutch BSN,
//     German Steuer-ID, US passport numbers, a bare nine-digit SSN): they cannot be told from any
//     other number in a note, and a member's deny list can carry them as an id entry.
export const governmentId = shapes("pii: government id", "Government ids: US SSN and ITIN, Canadian SIN, UK NINO and NHS, Spanish DNI, Brazilian CPF, Italian codice fiscale, Indian Aadhaar, French NIR", [
  { name: "US SSN", pattern: /(?<![\w-])(?!000|666|9\d\d)\d{3}([- ])(?!00)\d{2}\1(?!0000)\d{4}(?![\w-])/ },
  { name: "US ITIN", pattern: /(?<![\w-])9\d{2}([- ])(?:5\d|6[0-5]|7\d|8[0-8]|9[0-2]|9[4-9])\1\d{4}(?![\w-])/ },
  { name: "Canadian SIN", pattern: /(?<![\w-])\d{3}([- ])\d{3}\1\d{3}(?![\w-])/, valid: (m) => luhn(digitsOf(m[0])) },
  { name: "UK National Insurance number", pattern: /(?<![A-Z\d])(?!BG|GB|KN|NK|NT|TN|ZZ)[A-CEGHJ-PR-TW-Z][A-CEGHJ-NPR-TW-Z] ?\d{2} ?\d{2} ?\d{2} ?[A-D](?![A-Z\d])/ },
  { name: "UK NHS number", pattern: /(?<![\w-])\d{3}([- ])\d{3}\1\d{4}(?![\w-])/, valid: (m) => nhsValid(digitsOf(m[0])) },
  { name: "Spanish DNI or NIE", pattern: /(?<![A-Za-z\d])(?:\d{8}|[XYZ]\d{7})-?[A-HJ-NP-TV-Z](?![A-Za-z\d])/, valid: (m) => dniValid(m[0].replace("-", "")) },
  { name: "Brazilian CPF", pattern: /(?<![\w-])\d{3}\.\d{3}\.\d{3}-\d{2}(?![\w-])/, valid: (m) => cpfValid(digitsOf(m[0])) },
  { name: "Italian codice fiscale", pattern: /(?<![A-Z\d])[A-Z]{6}\d{2}[A-EHLMPRST]\d{2}[A-Z]\d{3}[A-Z](?![A-Z\d])/, valid: (m) => codiceFiscaleValid(m[0]) },
  { name: "Indian Aadhaar", pattern: /(?<![\w-])[2-9]\d{3}([- ])\d{4}\1\d{4}(?![\w-])/, valid: (m) => verhoeffValid(digitsOf(m[0])) },
  { name: "French NIR", pattern: /(?<![\w-])[12] ?\d{2} ?(?:0[1-9]|1[0-2]|20) ?(?:\d{2}|2[AB]) ?\d{3} ?\d{3} ?\d{2}(?![\w-])/i, valid: (m) => nirValid(m[0].replace(/ /g, "")) },
]);

// Payment card numbers: 13 to 19 digits, in groups separated by single spaces or dashes or not at
// all, beginning with 3 to 6 or with 22 to 27 (the major networks' ranges, Mastercard's 2-series
// among them), Luhn-valid. A unix timestamp in milliseconds has thirteen digits and begins with 1,
// and is not a card.
export const paymentCard = shapes("pii: payment card number", "Payment card numbers, Luhn-checked", [
  {
    name: "",
    pattern: /(?<![\d-])(?:[3-6](?:[ -]?\d){12,18}|2[ -]?[2-7](?:[ -]?\d){11,17})(?![\d-])/,
    valid: (m) => {
      const d = digitsOf(m[0]);
      return d.length >= 13 && d.length <= 19 && luhn(d);
    },
  },
]);

// Bank account numbers. IBAN: a country code, two check digits and 11 to 30 more characters, in
// groups of four or unbroken, mod-97 valid. US: an ABA routing number (nine digits with the
// 3-7-1 check, in a Federal Reserve range) followed within forty characters by an account number
// of 6 to 17 digits; a routing number alone names a bank, not a member.
export const bankAccount = shapes("pii: bank account number", "Bank account numbers: IBAN with checksum, US routing and account pairs", [
  {
    name: "IBAN",
    pattern: /(?<![A-Z\d])[A-Z]{2}\d{2}(?:[ -]?[A-Z0-9]{4}){2,7}(?:[ -]?[A-Z0-9]{1,4})?(?![A-Z\d])/,
    valid: (m) => ibanValid(m[0].replace(/[ -]/g, "")),
  },
  {
    name: "US routing and account",
    pattern: /(?<!\d)((?:0\d|1[0-2]|2[1-9]|3[0-2]|6[1-9]|7[0-2]|80)\d{7})(?!\d)[^\d\n]{1,40}?(?<!\d)\d{6,17}(?!\d)/,
    valid: (m) => abaValid(m[1]!),
  },
]);

// Crypto wallet addresses and keys, each by the check its format carries. Base58Check (Bitcoin,
// Litecoin and Dogecoin legacy and script addresses, WIF private keys, BIP32 extended keys): the
// double-SHA-256 checksum and a payload of an address's, a key's or an extended key's length.
// Bech32 and bech32m (SegWit and Taproot addresses on Bitcoin and Litecoin, and their testnets):
// the BIP173 checksum. Ethereum and every EVM chain: 0x and forty hex digits, a shape nothing else
// in ordinary work has; its mixed-case checksum needs Keccak, which a shape this specific does not.
//   Not detected: formats with no checksum and no distinct shape (a Solana address is any 32 to 44
//   base58 characters), and a dollar amount or a word such as "bank": neither can be told from
//   ordinary work.
export const cryptoWallet = shapes("pii: crypto wallet address or key", "Crypto wallet addresses and keys: Base58Check, bech32 and Ethereum, checksum-verified where the format has one", [
  {
    name: "Base58Check",
    pattern: /(?<![A-Za-z0-9])[1-9A-HJ-NP-Za-km-z]{25,112}(?![A-Za-z0-9])/,
    valid: (m) => [21, 33, 34, 78].includes(base58checkPayload(m[0])?.length ?? 0),
  },
  { name: "bech32", pattern: /(?<![A-Za-z0-9])(?:bc|tb|ltc|tltc)1[ac-hj-np-z02-9]{8,87}(?![A-Za-z0-9])/i, valid: (m) => bech32Valid(m[0]) },
  { name: "Ethereum", pattern: /(?<![A-Za-z0-9])0x[0-9a-fA-F]{40}(?![A-Za-z0-9])/ },
]);

/**
 * Recovery phrases (BIP39): 12, 15, 18, 21 or 24 consecutive words from the English list whose
 * checksum holds. Words are read lowercase and apart from anything between them, so a numbered
 * list or a comma-separated line is read the same as a spaced one. Prose rarely strings twelve list
 * words together (the, and, of and is are not on it), and the checksum then lets through all but
 * one in sixteen of the runs that do.
 */
export const recoveryPhrase: Detector = {
  name: "pii: recovery phrase",
  description: "Crypto wallet recovery phrases: BIP39 English words with a valid checksum",
  test(text) {
    const words = text.toLowerCase().split(/[^a-z]+/).filter((w) => w !== "");
    let run: string[] = [];
    const runTrips = () => {
      for (const n of [24, 21, 18, 15, 12]) {
        for (let i = 0; i + n <= run.length; i++) if (bip39Valid(run.slice(i, i + n))) return true;
      }
      return false;
    };
    for (const w of [...words, ""]) {
      if (isBip39Word(w)) {
        run.push(w);
        continue;
      }
      if (run.length >= 12 && runTrips()) return this.name;
      run = [];
    }
    return undefined;
  },
};

/** The detectors in the order they run; the first trip wins. */
export const detectors: Detector[] = [email, phone, streetAddress, governmentId, paymentCard, bankAccount, cryptoWallet, recoveryPhrase];

function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * The text with every allowed name (a member's or an agent's, as the circle names them) blanked,
 * whole words only, case-insensitively, each replaced by a single space so nothing on either side
 * runs together.
 */
export function maskAllowed(text: string, allowed: string[]): string {
  const names = allowed.map((n) => n.trim()).filter((n) => n !== "");
  if (names.length === 0) return text;
  const alternation = names.sort((a, b) => b.length - a.length).map(escapeRegExp).join("|");
  const re = new RegExp(String.raw`(?<![\p{L}\p{N}_])(?:${alternation})(?![\p{L}\p{N}_])`, "giu");
  return text.replace(re, " ");
}

export type Verdict = { ok: true } | { ok: false; rule: string };

/**
 * Runs every detector over the text with the allowed names masked. The verdict names the rule
 * that tripped and nothing of the text. The email detector reads the text unmasked: an address is
 * never a name, and a name blanked out of its local part (athena@example.com with Athena allowed)
 * would otherwise leave no address to find.
 */
export function screenPii(text: string, allowed: string[] = []): Verdict {
  const masked = maskAllowed(text, allowed);
  for (const d of detectors) {
    const rule = d.test(d === email ? text : masked);
    if (rule !== undefined) return { ok: false, rule };
  }
  return { ok: true };
}
