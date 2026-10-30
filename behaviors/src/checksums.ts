// Check digits the detectors verify, so a shape alone does not trip: a run of digits that happens
// to look like a card number is let through unless it is also Luhn-valid. Each function takes the
// digits (and letters, for the alphanumeric ones) with separators already removed.

/** Luhn (ISO/IEC 7812): payment cards, Canadian SINs. */
export function luhn(digits: string): boolean {
  let sum = 0;
  let double = false;
  for (let i = digits.length - 1; i >= 0; i--) {
    let d = digits.charCodeAt(i) - 48;
    if (d < 0 || d > 9) return false;
    if (double) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
    double = !double;
  }
  return digits.length > 0 && sum % 10 === 0;
}

/** ISO 13616 mod-97: the country code and check digits moved to the end, letters as 10..35. */
export function ibanValid(iban: string): boolean {
  const s = iban.toUpperCase();
  if (s.length < 15 || s.length > 34) return false;
  const rearranged = s.slice(4) + s.slice(0, 4);
  let remainder = 0;
  for (const ch of rearranged) {
    const code = ch.charCodeAt(0);
    let piece: string;
    if (code >= 48 && code <= 57) piece = ch;
    else if (code >= 65 && code <= 90) piece = String(code - 55);
    else return false;
    for (const d of piece) remainder = (remainder * 10 + (d.charCodeAt(0) - 48)) % 97;
  }
  return remainder === 1;
}

/** ABA routing transit number: nine digits, weights 3-7-1. */
export function abaValid(digits: string): boolean {
  if (!/^\d{9}$/.test(digits)) return false;
  const d = Array.from(digits, (c) => c.charCodeAt(0) - 48);
  const sum = 3 * (d[0]! + d[3]! + d[6]!) + 7 * (d[1]! + d[4]! + d[7]!) + (d[2]! + d[5]! + d[8]!);
  return sum % 10 === 0;
}

/** UK NHS number: ten digits, mod 11. */
export function nhsValid(digits: string): boolean {
  if (!/^\d{10}$/.test(digits)) return false;
  const d = Array.from(digits, (c) => c.charCodeAt(0) - 48);
  let sum = 0;
  for (let i = 0; i < 9; i++) sum += (10 - i) * d[i]!;
  let check = 11 - (sum % 11);
  if (check === 11) check = 0;
  return check !== 10 && check === d[9];
}

/** Brazilian CPF: eleven digits, two check digits, all-equal runs refused. */
export function cpfValid(digits: string): boolean {
  if (!/^\d{11}$/.test(digits) || /^(\d)\1{10}$/.test(digits)) return false;
  const d = Array.from(digits, (c) => c.charCodeAt(0) - 48);
  const dv = (n: number) => {
    let sum = 0;
    for (let i = 0; i < n; i++) sum += d[i]! * (n + 1 - i);
    const r = (sum * 10) % 11;
    return r === 10 ? 0 : r;
  };
  return dv(9) === d[9] && dv(10) === d[10];
}

const VERHOEFF_D = [
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
  [1, 2, 3, 4, 0, 6, 7, 8, 9, 5],
  [2, 3, 4, 0, 1, 7, 8, 9, 5, 6],
  [3, 4, 0, 1, 2, 8, 9, 5, 6, 7],
  [4, 0, 1, 2, 3, 9, 5, 6, 7, 8],
  [5, 9, 8, 7, 6, 0, 4, 3, 2, 1],
  [6, 5, 9, 8, 7, 1, 0, 4, 3, 2],
  [7, 6, 5, 9, 8, 2, 1, 0, 4, 3],
  [8, 7, 6, 5, 9, 3, 2, 1, 0, 4],
  [9, 8, 7, 6, 5, 4, 3, 2, 1, 0],
];
const VERHOEFF_P = [
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
  [1, 5, 7, 6, 2, 8, 3, 0, 9, 4],
  [5, 8, 0, 3, 7, 9, 6, 1, 4, 2],
  [8, 9, 1, 6, 0, 4, 3, 5, 2, 7],
  [9, 4, 5, 3, 1, 2, 6, 8, 7, 0],
  [4, 2, 8, 6, 5, 7, 3, 9, 0, 1],
  [2, 7, 9, 3, 8, 0, 6, 4, 1, 5],
  [7, 0, 4, 6, 9, 1, 3, 2, 5, 8],
];

/** Verhoeff: Indian Aadhaar numbers. */
export function verhoeffValid(digits: string): boolean {
  if (!/^\d+$/.test(digits)) return false;
  let c = 0;
  for (let i = 0; i < digits.length; i++) {
    const d = digits.charCodeAt(digits.length - 1 - i) - 48;
    c = VERHOEFF_D[c]![VERHOEFF_P[i % 8]![d]!]!;
  }
  return c === 0;
}

/** Spanish DNI (eight digits) and NIE (X, Y or Z and seven digits): the check letter. */
export function dniValid(id: string): boolean {
  const m = /^([XYZ]?)(\d{7,8})([A-Z])$/.exec(id.toUpperCase());
  if (!m) return false;
  const prefix = { "": "", X: "0", Y: "1", Z: "2" }[m[1]!] ?? "";
  if ((m[1] === "" && m[2]!.length !== 8) || (m[1] !== "" && m[2]!.length !== 7)) return false;
  const n = Number(prefix + m[2]!);
  return "TRWAGMYFPDXBNJZSQVHLCKE"[n % 23] === m[3];
}

const CF_ODD: Record<string, number> = {
  "0": 1, "1": 0, "2": 5, "3": 7, "4": 9, "5": 13, "6": 15, "7": 17, "8": 19, "9": 21,
  A: 1, B: 0, C: 5, D: 7, E: 9, F: 13, G: 15, H: 17, I: 19, J: 21, K: 2, L: 4, M: 18,
  N: 20, O: 11, P: 3, Q: 6, R: 8, S: 12, T: 14, U: 16, V: 10, W: 22, X: 25, Y: 24, Z: 23,
};

/** Italian codice fiscale: sixteen characters, the last a check character. */
export function codiceFiscaleValid(code: string): boolean {
  const s = code.toUpperCase();
  if (!/^[A-Z0-9]{16}$/.test(s)) return false;
  let sum = 0;
  for (let i = 0; i < 15; i++) {
    const ch = s[i]!;
    // Positions are counted from one: the first character is odd.
    if (i % 2 === 0) sum += CF_ODD[ch]!;
    else sum += /\d/.test(ch) ? Number(ch) : ch.charCodeAt(0) - 65;
  }
  return String.fromCharCode(65 + (sum % 26)) === s[15];
}

/** French NIR: thirteen digits (2A/2B for Corsica) and a two-digit key, 97 minus the number mod 97. */
export function nirValid(digits: string): boolean {
  const m = /^(\d{5})(\d{2}|2A|2B)(\d{6})(\d{2})$/i.exec(digits.toUpperCase());
  if (!m) return false;
  const dept = m[2]!.toUpperCase() === "2A" ? "19" : m[2]!.toUpperCase() === "2B" ? "18" : m[2]!;
  const number = m[1]! + dept + m[3]!;
  let remainder = 0;
  for (const d of number) remainder = (remainder * 10 + (d.charCodeAt(0) - 48)) % 97;
  return 97 - remainder === Number(m[4]);
}
