// The digest email (docs/protocol.md "The digest"): the sealed plaintext a node wrote, rendered
// to text and HTML with every option's link replaced by its URL. Pure, so the snapshot tests
// (test/render.test.ts, fixtures under test/fixtures) pin the exact output.
import type { Json } from "../../conformance/src/encoding.ts";
import { COLOR, FONT, RADIUS, SIZE, SPACE } from "./theme.ts";

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

/** The HTML email: the web UI's look (src/theme.ts) as inline styles, since mail clients ignore stylesheets. */
export function renderHtml(digest: DigestPlaintext, url: LinkUrl): string {
  const e = escapeHtml;
  const c = (name: keyof typeof COLOR): string => COLOR[name].light;
  const card = `background:${c("card")};border:1px solid ${c("line")};border-radius:${RADIUS.card};margin:0 0 ${SPACE.s4}`;
  const heading = `margin:${SPACE.s6} 0 ${SPACE.s2};font-size:${SIZE.xs};font-weight:500;letter-spacing:.025em;text-transform:uppercase;color:${c("muted")}`;
  const parts: string[] = [];
  parts.push(`<h1 style="margin:0 0 ${SPACE.s4};font-size:${SIZE.xl};font-weight:600;line-height:1.3;color:${c("text")}">${e(digest.subject)}</h1>`);
  for (const section of digest.sections) {
    parts.push(`<h2 style="${heading}">${e(section.title)}</h2>`);
    const rows = section.lines.map(
      (line, i) =>
        `<div style="padding:${SPACE.s3} ${SPACE.s4};font-size:${SIZE.sm};${i === 0 ? "" : `border-top:1px solid ${c("line")};`}">${e(line)}</div>`,
    );
    parts.push(`<div style="${card}">${rows.join("")}</div>`);
  }
  if (digest.asks.length > 0) {
    parts.push(`<h2 style="${heading}">Asks</h2>`);
    for (const ask of digest.asks) {
      parts.push(`<div style="${card};padding:${SPACE.s4}">`);
      parts.push(`<h3 style="margin:0 0 ${SPACE.s2};font-size:${SIZE.base};font-weight:600;color:${c("text")}">${e(ask.title)}</h3>`);
      if (ask.detail !== undefined && ask.detail !== "") parts.push(`<p style="margin:0 0 ${SPACE.s3};font-size:${SIZE.sm};color:${c("text")}">${e(ask.detail)}</p>`);
      for (const option of ask.options) {
        const base = `display:block;margin:0 0 ${SPACE.s2};padding:${SPACE.s3} ${SPACE.s4};min-height:20px;border-radius:${RADIUS.control};font-size:${SIZE.sm};font-weight:500;text-align:center;text-decoration:none`;
        const style = option.recommended
          ? `${base};background:${c("accentFill")};border:1px solid ${c("accentFill")};color:${c("onAccent")}`
          : `${base};background:${c("card")};border:1px solid ${c("buttonLine")};color:${c("text")}`;
        const mark = option.recommended ? " (recommended)" : "";
        parts.push(`<a href="${e(url(option.link))}" style="${style}">${e(option.label)}${e(mark)}</a>`);
      }
      const lapse = lapseLine(ask);
      if (lapse !== undefined) parts.push(`<p style="margin:${SPACE.s1} 0 0;font-size:${SIZE.xs};color:${c("muted")}">${e(lapse)}</p>`);
      parts.push(`</div>`);
    }
  }
  parts.push(
    `<p style="margin:${SPACE.s6} 0 0;font-size:${SIZE.xs};color:${c("muted")}">Each link answers once and expires when its ask lapses. Once an ask is answered, its other links stop working.</p>`,
  );
  return [
    `<!doctype html>`,
    `<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="color-scheme" content="light"><title>${e(digest.subject)}</title></head>`,
    `<body style="margin:0;background:${c("page")}"><div style="max-width:560px;margin:0 auto;padding:${SPACE.s6} ${SPACE.s4};font-family:${FONT};font-size:${SIZE.base};line-height:1.5;color:${c("text")}">`,
    ...parts,
    `</div></body></html>`,
    ``,
  ].join("\n");
}

export function renderEmail(digest: DigestPlaintext, url: LinkUrl): Email {
  return { subject: digest.subject, text: renderText(digest, url), html: renderHtml(digest, url) };
}
