// The digest email (docs/protocol.md "The digest"): the sealed plaintext a node wrote, rendered
// to text and HTML with every option's link replaced by its URL. Pure, so the snapshot tests
// (test/render.test.ts, fixtures under test/fixtures) pin the exact output.
import type { Json } from "../../conformance/src/encoding.ts";

export interface DigestOption {
  label: string;
  recommended?: boolean;
  /** The link id (docs/protocol.md "Answer links"); the email carries its URL. */
  link: string;
  /** Optional: the option id, so on_no_answer can be shown by label. */
  id?: string;
}

export interface DigestAsk {
  ask: string;
  title: string;
  detail?: string;
  /** The option id taken when nobody answers. */
  on_no_answer?: string;
  lapses_at?: string;
  options: DigestOption[];
}

export interface DigestSection {
  title: string;
  lines: string[];
}

export interface DigestPlaintext {
  to: string;
  subject: string;
  sections: DigestSection[];
  asks: DigestAsk[];
}

function isObject(value: unknown): value is { [key: string]: Json } {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function str(object: { [key: string]: Json }, field: string, where: string): string {
  const value = object[field];
  if (typeof value !== "string") throw new Error(`${where}.${field} is not a string`);
  return value;
}

function optionalStr(object: { [key: string]: Json }, field: string, where: string): string | undefined {
  const value = object[field];
  if (value === undefined) return undefined;
  if (typeof value !== "string") throw new Error(`${where}.${field} is not a string`);
  return value;
}

function list(object: { [key: string]: Json }, field: string, where: string): Json[] {
  const value = object[field];
  if (!Array.isArray(value)) throw new Error(`${where}.${field} is not a list`);
  return value;
}

/** The digest plaintext's shape, or an Error naming the first field that is not. */
export function parseDigestPlaintext(value: Json): DigestPlaintext {
  if (!isObject(value)) throw new Error("the digest plaintext is not an object");
  const to = str(value, "to", "digest");
  const subject = str(value, "subject", "digest");
  const sections = list(value, "sections", "digest").map((section, i) => {
    if (!isObject(section)) throw new Error(`digest.sections[${i}] is not an object`);
    const lines = list(section, "lines", `digest.sections[${i}]`).map((line, j) => {
      if (typeof line !== "string") throw new Error(`digest.sections[${i}].lines[${j}] is not a string`);
      return line;
    });
    return { title: str(section, "title", `digest.sections[${i}]`), lines };
  });
  const asks = list(value, "asks", "digest").map((ask, i) => {
    const where = `digest.asks[${i}]`;
    if (!isObject(ask)) throw new Error(`${where} is not an object`);
    const options = list(ask, "options", where).map((option, j) => {
      const at = `${where}.options[${j}]`;
      if (!isObject(option)) throw new Error(`${at} is not an object`);
      const id = optionalStr(option, "id", at);
      return {
        label: str(option, "label", at),
        ...(option["recommended"] === true ? { recommended: true } : {}),
        link: str(option, "link", at),
        ...(id === undefined ? {} : { id }),
      };
    });
    if (options.length === 0) throw new Error(`${where} has no options`);
    const detail = optionalStr(ask, "detail", where);
    const onNoAnswer = optionalStr(ask, "on_no_answer", where);
    const lapsesAt = optionalStr(ask, "lapses_at", where);
    return {
      ask: str(ask, "ask", where),
      title: str(ask, "title", where),
      ...(detail === undefined ? {} : { detail }),
      ...(onNoAnswer === undefined ? {} : { on_no_answer: onNoAnswer }),
      ...(lapsesAt === undefined ? {} : { lapses_at: lapsesAt }),
      options,
    };
  });
  return { to, subject, sections, asks };
}

/** Every link id the plaintext's options name. */
export function linkIds(digest: DigestPlaintext): string[] {
  return digest.asks.flatMap((ask) => ask.options.map((option) => option.link));
}

export function escapeHtml(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

/** An ISO time as "2026-11-01 15:00 UTC"; anything that does not parse is shown as written. */
export function formatWhen(iso: string): string {
  const ms = Date.parse(iso);
  if (Number.isNaN(ms)) return iso;
  return new Date(ms).toISOString().slice(0, 16).replace("T", " ") + " UTC";
}

/** What an ask says happens with no answer: the option's label when the options carry ids, the id otherwise. */
function noAnswerLabel(ask: DigestAsk): string | undefined {
  if (ask.on_no_answer === undefined) return undefined;
  const option = ask.options.find((o) => o.id === ask.on_no_answer);
  return option === undefined ? ask.on_no_answer : option.label;
}

function lapseLine(ask: DigestAsk): string | undefined {
  const answer = noAnswerLabel(ask);
  if (ask.lapses_at === undefined && answer === undefined) return undefined;
  if (ask.lapses_at === undefined) return `No answer counts as "${answer ?? ""}".`;
  if (answer === undefined) return `Lapses ${formatWhen(ask.lapses_at)}.`;
  return `No answer by ${formatWhen(ask.lapses_at)} counts as "${answer}".`;
}

export type LinkUrl = (id: string) => string;

export interface Email {
  subject: string;
  text: string;
  html: string;
}

export function renderText(digest: DigestPlaintext, url: LinkUrl): string {
  const out: string[] = [digest.subject, "=".repeat(digest.subject.length), ""];
  for (const section of digest.sections) {
    out.push(section.title, "-".repeat(section.title.length));
    for (const line of section.lines) out.push(line);
    out.push("");
  }
  if (digest.asks.length > 0) {
    out.push("Asks", "----", "");
    for (const ask of digest.asks) {
      out.push(ask.title);
      if (ask.detail !== undefined && ask.detail !== "") out.push(ask.detail);
      out.push("");
      for (const option of ask.options) {
        out.push(`  ${option.label}${option.recommended ? " (recommended)" : ""}`, `  ${url(option.link)}`, "");
      }
      const lapse = lapseLine(ask);
      if (lapse !== undefined) out.push(lapse, "");
    }
  }
  return out.join("\n");
}

export function renderHtml(digest: DigestPlaintext, url: LinkUrl): string {
  const e = escapeHtml;
  const parts: string[] = [];
  parts.push(`<h1 style="font-size:20px;margin:0 0 16px">${e(digest.subject)}</h1>`);
  for (const section of digest.sections) {
    parts.push(`<h2 style="font-size:16px;margin:24px 0 8px">${e(section.title)}</h2>`);
    parts.push(`<ul style="margin:0;padding-left:20px">${section.lines.map((line) => `<li style="margin:4px 0">${e(line)}</li>`).join("")}</ul>`);
  }
  if (digest.asks.length > 0) {
    parts.push(`<h2 style="font-size:16px;margin:24px 0 8px">Asks</h2>`);
    for (const ask of digest.asks) {
      parts.push(`<div style="margin:0 0 24px;padding:12px 16px;border:1px solid #ddd;border-radius:6px">`);
      parts.push(`<h3 style="font-size:16px;margin:0 0 8px">${e(ask.title)}</h3>`);
      if (ask.detail !== undefined && ask.detail !== "") parts.push(`<p style="margin:0 0 12px">${e(ask.detail)}</p>`);
      parts.push(`<p style="margin:0 0 12px">`);
      for (const option of ask.options) {
        const style = option.recommended
          ? "display:inline-block;margin:0 8px 8px 0;padding:8px 14px;border-radius:4px;background:#1a5fb4;color:#fff;font-weight:bold;text-decoration:none"
          : "display:inline-block;margin:0 8px 8px 0;padding:8px 14px;border-radius:4px;border:1px solid #1a5fb4;color:#1a5fb4;text-decoration:none";
        const mark = option.recommended ? " (recommended)" : "";
        parts.push(`<a href="${e(url(option.link))}" style="${style}">${e(option.label)}${e(mark)}</a>`);
      }
      parts.push(`</p>`);
      const lapse = lapseLine(ask);
      if (lapse !== undefined) parts.push(`<p style="margin:0;color:#555;font-size:14px">${e(lapse)}</p>`);
      parts.push(`</div>`);
    }
  }
  return [
    `<!doctype html>`,
    `<html><head><meta charset="utf-8"><title>${e(digest.subject)}</title></head>`,
    `<body style="font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;color:#222;max-width:640px;margin:0 auto;padding:24px 16px;line-height:1.45">`,
    ...parts,
    `</body></html>`,
    ``,
  ].join("\n");
}

export function renderEmail(digest: DigestPlaintext, url: LinkUrl): Email {
  return { subject: digest.subject, text: renderText(digest, url), html: renderHtml(digest, url) };
}
