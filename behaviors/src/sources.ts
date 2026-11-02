// The sources a member may let their agent read, shaped like the node's local API
// (spec/digestif-node.json: enum source_kind, models source and sources_form). A behavior is given
// the node's list and the member's choice and never discovers sources of its own. The nightly
// hook's sources also carry where each starts (docs/behaviors.md, What a behavior is handed).

import { parseTime, type Start } from "./record.ts";

export type SourceKind = "claude_code" | "git" | "command";

/** One approved repository of the git source: one remote, every clone of it. */
export interface Repository extends Start {
  id: string;
  name: string;
  paths: string[];
}

/** A commit author the member owns. */
export interface Author extends Start {
  email: string;
}

export interface Source extends Partial<Start> {
  id: string;
  kind: SourceKind;
  label: string;
  /** Shown with ~ for the home directory, the way the node reports them. For a command source, the program and then its arguments. */
  paths: string[];
  yields: string[];
  selected: boolean;
  /** The git source: the approved repositories, each with its start. Absent: each path is one. */
  repositories?: Repository[];
  /** The git source: the authors the member owns, each with its start. null or absent: every author. */
  authors?: Author[] | null;
}

function startOf(o: Record<string, unknown>): Start {
  const start = parseTime(o["start"]);
  return {
    recorded: o["recorded"] === true,
    ...(start === undefined ? {} : { start }),
    ...(typeof o["sha"] === "string" && o["sha"] !== "" ? { sha: o["sha"] } : {}),
  };
}

/**
 * The record fields of a source as the node hands them over: its start, and the git source's
 * repositories and authors. Fields the node does not send are left out.
 */
export function recordFields(o: Record<string, unknown>): Partial<Source> {
  const out: Partial<Source> = {};
  if (o["start"] !== undefined) Object.assign(out, startOf(o));
  if (Array.isArray(o["repositories"])) {
    out.repositories = (o["repositories"] as unknown[]).flatMap((r) => {
      if (typeof r !== "object" || r === null) return [];
      const x = r as Record<string, unknown>;
      if (typeof x["id"] !== "string" || !isStringArray(x["paths"])) return [];
      return [{ id: x["id"], name: typeof x["name"] === "string" ? x["name"] : x["id"], paths: x["paths"], ...startOf(x) }];
    });
  }
  if (o["authors"] === null) out.authors = null;
  else if (Array.isArray(o["authors"])) {
    out.authors = (o["authors"] as unknown[]).flatMap((a) => {
      if (typeof a !== "object" || a === null || typeof (a as Record<string, unknown>)["email"] !== "string") return [];
      const x = a as Record<string, unknown>;
      return [{ email: x["email"] as string, ...startOf(x) }];
    });
  }
  return out;
}

/** sources_form: source ids. Empty is a valid answer: the member reads and answers only. */
export interface SourcesForm {
  selected: string[];
}

/** The sources to extract from: the form's ids when a form is given, else the selected flags. */
export function chosen(sources: Source[], form?: SourcesForm): Source[] {
  if (form === undefined) return sources.filter((s) => s.selected);
  const ids = new Set(form.selected);
  return sources.filter((s) => ids.has(s.id));
}

/** A path as the node reports it, with ~ expanded to the home directory. */
export function untilde(path: string, home: string): string {
  return path.startsWith("~") ? home + path.slice(1) : path;
}

function isStringArray(v: unknown): v is string[] {
  return Array.isArray(v) && v.every((x) => typeof x === "string");
}

function isSource(v: unknown): v is Source {
  if (typeof v !== "object" || v === null) return false;
  const o = v as Record<string, unknown>;
  return (
    typeof o.id === "string" &&
    (o.kind === "claude_code" || o.kind === "git" || o.kind === "command") &&
    typeof o.label === "string" &&
    isStringArray(o.paths) &&
    isStringArray(o.yields) &&
    typeof o.selected === "boolean"
  );
}

/**
 * The selection as the extract command reads it: either the node's `[source]` list (GET /sources,
 * with the selected flags) or `{ "sources": [source], "form": sources_form }`.
 */
export function parseSelection(json: unknown): { sources: Source[]; form?: SourcesForm } {
  if (Array.isArray(json)) {
    if (!json.every(isSource)) throw new Error("every element must be a source (spec/digestif-node.json)");
    return { sources: json.map((s) => ({ ...s, ...recordFields(s as unknown as Record<string, unknown>) })) };
  }
  if (typeof json === "object" && json !== null) {
    const o = json as Record<string, unknown>;
    if (Array.isArray(o.sources) && o.sources.every(isSource)) {
      const sources = o.sources.map((s) => ({ ...s, ...recordFields(s as unknown as Record<string, unknown>) }));
      const form = o.form;
      if (form === undefined) return { sources };
      if (typeof form === "object" && form !== null && isStringArray((form as Record<string, unknown>).selected)) {
        return { sources, form: { selected: (form as SourcesForm).selected } };
      }
      throw new Error("form must be a sources_form: { selected: [string] }");
    }
  }
  throw new Error("expected [source] or { sources: [source], form?: sources_form }");
}
