// The record and where each note starts (docs/behaviors.md, What a behavior is handed; DES-37265).
// A note covers no calendar day. Per source it starts where the last approved note ended, which
// the node records and hands over as each source's start; a note fixes where it ends when it is
// written, and the node moves each source there when the note is approved. This module is the
// arithmetic of that: the first note's reach, the oldest-first record limit, and each source's end.

/** The first note reads the last 24 hours... */
export const FIRST_NOTE_MS = 24 * 3_600_000;
/** ...and, with fewer than this many items in them, reads back until it has this many... */
export const FIRST_NOTE_ITEMS = 100;
/** ...as far as this. */
export const FIRST_NOTE_REACH_MS = 30 * 24 * 3_600_000;
/** A source with no recorded point starts this long before it was approved. */
export const FRESH_MS = 24 * 3_600_000;

/**
 * The record limit, read oldest first: a version reads at most this many items from the oldest
 * unread one, and the rest waits for the next note. node/web/sources.ml, max_lines.
 */
export const RECORD_LIMIT = 500;
/** The record stops before the item that would take it past this many characters. */
export const MAX_RECORD_CHARS = 100_000;

/**
 * Where a source starts, as the node hands it over. `start` absent: no note has been approved
 * yet, so the source reads the first note's reach. `recorded`: the start is where an approved
 * note ended (a point), not the 24 hours before the source was approved.
 */
export interface Start {
  /** Epoch milliseconds. */
  start?: number;
  /** A repository's point: the newest default-branch commit the last approved note read. */
  sha?: string;
  recorded: boolean;
}

/** Where a note ends for one source: what `digestif note --ends` carries per key. */
export interface End {
  /** Epoch milliseconds. */
  at: number;
  sha?: string;
}

/** The record keys the node uses (node/web/store.ml, Record). */
export const sourceKey = (id: string) => `source:${id}`;
export const repositoryKey = (id: string) => `repository:${id}`;
export const authorKey = (email: string) => `author:${email.trim().toLowerCase()}`;

/** One item of the record: a commit, a session's prompt or a command's line. */
export interface Item {
  /** The record key of the source it came from. */
  key: string;
  /** Epoch milliseconds: when it was recorded (a commit's committer time, a prompt's time). */
  at: number;
  /** The line's kind as the writer reads it: commit, prompt, or a command source's label. */
  kind: string;
  text: string;
  /** A session's title, rendered as its own line before the session's first prompt in the note's record. */
  title?: string;
  /** Read and counted, but noise to the writer, which leaves it out of the note. */
  bookkeeping?: boolean;
  /** A commit's sha. */
  sha?: string;
}

/** The lines an item renders to, as `kind: text`. */
export function itemLines(item: Item, titled: boolean): string[] {
  const own = `${item.bookkeeping ? `bookkeeping ${item.kind}` : item.kind}: ${item.text}`;
  return titled && item.title !== undefined ? [`session: ${item.title}`, own] : [own];
}

const chars = (lines: string[]) => lines.reduce((n, l) => n + l.length + 1, 0);
/** One session's title line, once per source. */
const titleKey = (item: Item) => (item.title === undefined ? undefined : `${item.key}\u0000${item.title}`);

/**
 * The cutoff of the first note's reach: the last 24 hours, or further back until there are
 * FIRST_NOTE_ITEMS items, as far as 30 days. Every item at or after it is in the first note.
 */
export function firstNoteCutoff(items: Item[], now: number): number {
  const day = now - FIRST_NOTE_MS;
  const reach = now - FIRST_NOTE_REACH_MS;
  const newestFirst = items.filter((i) => i.at >= reach && i.at <= now).sort((a, b) => b.at - a.at);
  if (newestFirst.filter((i) => i.at >= day).length >= FIRST_NOTE_ITEMS) return day;
  const hundredth = newestFirst[FIRST_NOTE_ITEMS - 1];
  if (hundredth !== undefined) return Math.min(day, hundredth.at);
  const oldest = newestFirst[newestFirst.length - 1];
  return oldest === undefined ? day : Math.min(day, oldest.at);
}

export interface Limited {
  /** The items the note reads, oldest first. */
  kept: Item[];
  /** Whether any item waits for the next note. */
  cut: boolean;
  /** The time of the newest item kept, when anything was cut: the record reads through it. */
  through?: number;
  /** The keys with an item waiting for the next note. */
  cutKeys: Set<string>;
}

/**
 * The record limit, read oldest first: items in time order, up to RECORD_LIMIT and
 * MAX_RECORD_CHARS. Items of one time are not split: the limit stops before a time it cannot take
 * whole, so `through` covers every item at or before it.
 */
export function limitOldestFirst(items: Item[], limit = RECORD_LIMIT, maxChars = MAX_RECORD_CHARS): Limited {
  const sorted = items.map((item, i) => ({ item, i })).sort((a, b) => a.item.at - b.item.at || a.i - b.i);
  const kept: Item[] = [];
  const titled = new Set<string>();
  let used = 0;
  let n = 0;
  while (n < sorted.length) {
    // The run of items sharing this time.
    let m = n;
    while (m < sorted.length && sorted[m]!.item.at === sorted[n]!.item.at) m++;
    const run = sorted.slice(n, m).map((x) => x.item);
    const lines = run.flatMap((it) => itemLines(it, titleKey(it) !== undefined && !titled.has(titleKey(it)!)));
    if (kept.length + run.length > limit || used + chars(lines) > maxChars) break;
    for (const it of run) if (titleKey(it) !== undefined) titled.add(titleKey(it)!);
    kept.push(...run);
    used += chars(lines);
    n = m;
  }
  const rest = sorted.slice(n).map((x) => x.item);
  const cut = rest.length > 0;
  const through = cut ? kept[kept.length - 1]?.at : undefined;
  return { kept, cut, ...(through === undefined ? {} : { through }), cutKeys: new Set(rest.map((i) => i.key)) };
}

/** The record's lines, in time order, each session titled before its first prompt in it. */
export function render(items: Item[]): string[] {
  const titled = new Set<string>();
  const seen = new Set<string>();
  const out: string[] = [];
  for (const it of items) {
    const t = titleKey(it);
    for (const line of itemLines(it, t !== undefined && !titled.has(t))) {
      // Equal lines keep their first occurrence (node/web/sources.ml, dedupe).
      if (seen.has(line)) continue;
      seen.add(line);
      out.push(line);
    }
    if (t !== undefined) titled.add(t);
  }
  return out;
}

/** A whole-second ISO 8601 date time with its offset, such as 2026-11-01T03:50:00-05:00. Mirrors of_unix_at_offset in node/core/time_fmt.ml. */
export function dateTimeWithOffset(epochMs: number, utcOffsetMinutes?: number): string {
  const offset = utcOffsetMinutes ?? -new Date(epochMs).getTimezoneOffset();
  const wall = new Date(Math.floor(epochMs / 1000) * 1000 + offset * 60_000).toISOString().slice(0, 19);
  const p = (n: number) => String(n).padStart(2, "0");
  const abs = Math.abs(offset);
  return `${wall}${offset < 0 ? "-" : "+"}${p(Math.floor(abs / 60))}:${p(abs % 60)}`;
}

/** Parses an offset such as +02:00, -0500 or Z into minutes east of UTC. */
export function parseOffset(text: string): number {
  if (text === "Z" || text === "z") return 0;
  const m = /^([+-])(\d{2}):?(\d{2})$/.exec(text);
  if (!m) throw new Error(`not a UTC offset (+HH:MM): ${text}`);
  const minutes = Number(m[2]) * 60 + Number(m[3]);
  return m[1] === "-" ? -minutes : minutes;
}

/** Parses a start the node handed over: an ISO 8601 time, or null for the first note's reach. */
export function parseTime(v: unknown): number | undefined {
  if (typeof v !== "string") return undefined;
  const ms = Date.parse(v);
  return Number.isNaN(ms) ? undefined : ms;
}
