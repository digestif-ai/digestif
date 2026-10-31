// The sources a member may let their agent read, shaped like the node's local API
// (spec/digestif-node.json: enum source_kind, models source and sources_form). A behavior is given
// the node's list and the member's choice and never discovers sources of its own.

export type SourceKind = "claude_code" | "git" | "command";

export interface Source {
  id: string;
  kind: SourceKind;
  label: string;
  /** Shown with ~ for the home directory, the way the node reports them. For a command source, the program and then its arguments. */
  paths: string[];
  yields: string[];
  selected: boolean;
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
    return { sources: json };
  }
  if (typeof json === "object" && json !== null) {
    const o = json as Record<string, unknown>;
    if (Array.isArray(o.sources) && o.sources.every(isSource)) {
      const form = o.form;
      if (form === undefined) return { sources: o.sources };
      if (typeof form === "object" && form !== null && isStringArray((form as Record<string, unknown>).selected)) {
        return { sources: o.sources, form: { selected: (form as SourcesForm).selected } };
      }
      throw new Error("form must be a sources_form: { selected: [string] }");
    }
  }
  throw new Error("expected [source] or { sources: [source], form?: sources_form }");
}
