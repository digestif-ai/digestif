// Read: the first step of a note (docs/design.md, The note; DES-37265, The record and where each
// note starts). Code, not the agent, reads the record from the chosen sources, per source from
// where the last approved note ended: full commit messages with repository and sha from approved
// repositories and owned authors, session titles and the member's own prompts, and the lines of
// any command source; never a diff, tool output or assistant text. It answers the record, oldest
// first up to the record limit, and where the note it is written into ends for each source.

import { homedir } from "node:os";
import { commandLines } from "./command.ts";
import { isBookkeeping, messageLine, repositoryCommits, type Commit } from "./git.ts";
import {
  authorKey,
  dateTimeWithOffset,
  FIRST_NOTE_MS,
  FIRST_NOTE_REACH_MS,
  FRESH_MS,
  firstNoteCutoff,
  limitOldestFirst,
  render,
  repositoryKey,
  sourceKey,
  type End,
  type Item,
  type Start,
} from "./record.ts";
import { itemLine, MAX_ITEM_CHARS, ReadingOverran, sessionsSince, type Budget } from "./sessions.ts";
import { untilde, type Author, type Repository, type Source } from "./sources.ts";

export interface ReadOptions {
  /** The home directory ~ expands to in source paths. Defaults to the user's. */
  home?: string;
  /** The clock, epoch milliseconds. Read once as the record's end, and as each command is spawned. */
  now?: () => number;
  /** No note has been approved yet: every source reads the first note's reach. */
  firstNote: boolean;
  /** A command's --since in this fixed UTC offset instead of the machine's zone (tests pin it). */
  utcOffsetMinutes?: number;
  /**
   * How long one source may spend reading, in milliseconds of `elapsed`: a source past it is
   * abandoned as failed, naming the file it was in, and the rest are read. Unset: no limit.
   */
  sourceBudgetMs?: number;
  /** The clock a source's budget is measured on, in milliseconds. Defaults to the wall clock. */
  elapsed?: () => number;
  /** Told which source is being read, and in it which file, how many bytes and for how long. */
  onProgress?: (p: SourceProgress) => void;
  /** Lines for the run's log: each transcript read from its tail, and what it skipped. */
  log?: (line: string) => void;
  /** Each transcript's byte cap; defaults to DIGESTIF_MAX_TRANSCRIPT_BYTES or its default. */
  maxTranscriptBytes?: number;
}

/** Where the reading step is: the source, and the file in it with its bytes read so far. */
export interface SourceProgress {
  source: string;
  file?: string;
  bytes?: number;
  /** Milliseconds since this source's reading began. */
  elapsedMs: number;
}

/** A source abandoned because it spent its share of the deadline, and the file it was reading. */
export interface Overran {
  source: string;
  file: string;
}

export interface ReadRecord {
  /** The items the note reads, oldest first, after the first note's reach and the record limit. */
  items: Item[];
  /** Those items as the writer reads them, one per line, as `kind: text`. */
  lines: string[];
  /** Where the note ends, per record key: what approval moves each source to. */
  ends: Record<string, End>;
  /** Why each command source that failed gave no lines, naming it. */
  failures: string[];
  /** The label of each source that could not be read, and of each that was: a source's problem is its own. */
  failedSources: string[];
  readSources: string[];
  /** Each source abandoned for spending its share of the deadline (also in failedSources), with the file. */
  overran: Overran[];
  /** How many items were read before the record limit; the rest wait for the next note. */
  read: number;
}

/** Where a source starts: its own, else the first note's reach, else the 24 hours before now. */
function startOf(st: Partial<Start> | undefined, o: { firstNote: boolean; now: number }): number {
  if (o.firstNote) return o.now - FIRST_NOTE_REACH_MS;
  return st?.start ?? o.now - FRESH_MS;
}

interface RepoRead {
  key: string;
  repo: Repository;
  /** Every default-branch commit after the repository's start, whoever wrote it, oldest first. */
  commits: Commit[];
}

/**
 * The commits of one repository that enter the record. A commit is new when it is past the
 * repository's start; for an author with no point yet, added after the repository has one, past the
 * author's start instead, so their work in the last 24 hours is read and never their history.
 */
async function gitItems(repo: Repository, authors: Author[] | null | undefined, o: { firstNote: boolean; now: number }, paths: string[]): Promise<{ items: Item[]; read: RepoRead }> {
  const key = repositoryKey(repo.id);
  const repoStart = startOf(repo, o);
  const commits = await repositoryCommits(paths, { since: repoStart, ...(o.firstNote || repo.sha === undefined ? {} : { sha: repo.sha }) });
  const owned = authors === null || authors === undefined ? undefined : new Map(authors.map((a) => [a.email.trim().toLowerCase(), a]));
  // An author with no point, added after this repository got one: read from the author's start.
  const freshAuthors = o.firstNote || !repo.recorded || owned === undefined ? [] : [...owned.values()].filter((a) => !a.recorded && startOf(a, o) < repoStart);
  const earliest = Math.min(...freshAuthors.map((a) => startOf(a, o)));
  const older = freshAuthors.length === 0 ? [] : await repositoryCommits(paths, { since: earliest });
  const seen = new Set(commits.map((c) => c.sha));
  const candidates = [...commits, ...older.filter((c) => !seen.has(c.sha))].filter((c) => c.at <= o.now).sort((a, b) => a.at - b.at);
  const items: Item[] = [];
  for (const c of candidates) {
    const author = owned?.get(c.email);
    if (owned !== undefined && author === undefined) continue;
    const fresh = author !== undefined && !o.firstNote && !author.recorded;
    const isNew = !fresh
      ? seen.has(c.sha)
      : repo.recorded
        ? c.at > startOf(author, o)
        : seen.has(c.sha) && c.at > Math.max(repoStart, startOf(author, o));
    if (!isNew) continue;
    items.push({
      key,
      at: c.at,
      kind: "commit",
      text: `${repo.name} ${c.sha.slice(0, 12)}: ${messageLine(c.message, MAX_ITEM_CHARS)}`,
      sha: c.sha,
      ...(isBookkeeping(c) ? { bookkeeping: true } : {}),
    });
  }
  return { items, read: { key, repo, commits } };
}

interface SourceReading {
  budget?: Budget;
  onProgress?: (p: { file: string; bytes: number; elapsedMs: number }) => void;
  log?: (line: string) => void;
  maxBytes?: number;
}

async function sessionItems(source: Source, paths: string[], since: number, until: number, reading: SourceReading = {}): Promise<Item[]> {
  const key = sourceKey(source.id);
  const items: Item[] = [];
  for (const path of paths) {
    for (const s of await sessionsSince(path, since, until, reading)) {
      const title = itemLine(s.title);
      for (const p of s.prompts) {
        if (p.at <= since || p.at > until) continue;
        // A title that is the session's first prompt stands as the session's line, not as a prompt.
        if (p === s.titlePrompt) items.push({ key, at: p.at, kind: "session", text: title });
        else if (itemLine(p.text) !== "") items.push({ key, at: p.at, kind: "prompt", text: itemLine(p.text), ...(title === "" ? {} : { title }) });
      }
    }
  }
  return items;
}

/** The record from the chosen sources, and where a note written from it ends for each source. */
export async function readRecord(sources: Source[], options: ReadOptions): Promise<ReadRecord> {
  const home = options.home ?? homedir();
  const clock = options.now ?? Date.now;
  const now = clock();
  const o = { firstNote: options.firstNote, now };
  const items: Item[] = [];
  const failures: string[] = [];
  const failedSources: string[] = [];
  const readSources: string[] = [];
  const repos: RepoRead[] = [];
  const timeKeys: string[] = [];
  const commands: { key: string; spawned: number }[] = [];
  const overran: Overran[] = [];
  const elapsed = options.elapsed ?? Date.now;
  // One source's reading: its budget, measured from when it starts, and its progress, labelled.
  const readingOf = (label: string): SourceReading & { spent: () => boolean } => {
    const began = elapsed();
    const spent = (): boolean => options.sourceBudgetMs !== undefined && elapsed() - began > options.sourceBudgetMs;
    options.onProgress?.({ source: label, elapsedMs: 0 });
    return {
      spent,
      budget: { spent },
      onProgress: (p) => options.onProgress?.({ source: label, file: p.file, bytes: p.bytes, elapsedMs: elapsed() - began }),
      ...(options.log === undefined ? {} : { log: options.log }),
      ...(options.maxTranscriptBytes === undefined ? {} : { maxBytes: options.maxTranscriptBytes }),
    };
  };
  // A source that spent its share is failed as a whole: nothing it read enters the record and it
  // does not move, so the next note reads that window again.
  const abandon = (label: string, path: string): void => {
    const file = home.length > 1 && path.startsWith(home + "/") ? "~" + path.slice(home.length) : path;
    overran.push({ source: label, file });
    failures.push(`${label}: past its share of the deadline while reading ${file}`);
    failedSources.push(label);
  };
  for (const s of sources) {
    const paths = s.paths.map((p) => untilde(p, home));
    switch (s.kind) {
      case "git": {
        const list = s.repositories ?? paths.map((p) => ({ id: p, name: p.split("/").pop() ?? p, paths: [p], recorded: false }));
        const reading = readingOf(s.label);
        const got: { items: Item[]; read: RepoRead }[] = [];
        // A repository's commits come from one git call; the share is checked between them, and a
        // source past it names the repository it spent it in.
        let last: string | undefined;
        let stopped: string | undefined;
        for (const r of list) {
          if (last !== undefined && reading.spent()) {
            stopped = last;
            break;
          }
          const rpaths = r.paths.map((p) => untilde(p, home));
          last = rpaths[0] ?? r.name;
          reading.onProgress?.({ file: last, bytes: 0, elapsedMs: 0 });
          got.push(await gitItems(r, s.authors, o, rpaths));
        }
        if (stopped !== undefined) {
          abandon(s.label, stopped);
          break;
        }
        for (const g of got) {
          items.push(...g.items);
          repos.push(g.read);
        }
        for (const a of s.authors ?? []) timeKeys.push(authorKey(a.email));
        readSources.push(s.label);
        break;
      }
      case "claude_code": {
        try {
          items.push(...(await sessionItems(s, paths, startOf(s, o), now, readingOf(s.label))));
        } catch (e) {
          if (!(e instanceof ReadingOverran)) throw e;
          abandon(s.label, e.file);
          break;
        }
        timeKeys.push(sourceKey(s.id));
        readSources.push(s.label);
        break;
      }
      case "command": {
        // A command's lines carry no time: the first note asks for its last 24 hours, and they
        // stand at the start of the window they were asked for.
        readingOf(s.label);
        const since = options.firstNote ? now - FIRST_NOTE_MS : startOf(s, o);
        const spawned = clock();
        const r = await commandLines(paths, dateTimeWithOffset(since, options.utcOffsetMinutes), s.label);
        if (r.ok) {
          items.push(...r.lines.map((text) => ({ key: sourceKey(s.id), at: since, kind: s.label, text })));
          commands.push({ key: sourceKey(s.id), spawned });
          readSources.push(s.label);
        } else {
          failures.push(r.reason);
          failedSources.push(s.label);
        }
        break;
      }
    }
  }
  const reached = options.firstNote ? items.filter((i) => i.at >= firstNoteCutoff(items, now)) : items;
  const limited = limitOldestFirst(reached);
  const through = limited.through ?? now;
  const ends: Record<string, End> = {};
  for (const { key, repo, commits } of repos) {
    // The newest default-branch commit the record read through, whoever wrote it.
    const last = commits.filter((c) => c.at <= through).pop();
    if (last !== undefined) ends[key] = { at: last.at, sha: last.sha };
    else if (!options.firstNote && repo.recorded && repo.sha !== undefined && repo.start !== undefined) ends[key] = { at: repo.start, sha: repo.sha };
    else ends[key] = { at: through };
  }
  for (const key of timeKeys) ends[key] = { at: through };
  // A command with a line waiting is asked for the same window again: its lines carry no time.
  for (const { key, spawned } of commands) if (!limited.cutKeys.has(key)) ends[key] = { at: spawned };
  return { items: limited.kept, lines: render(limited.kept), ends, failures, failedSources, readSources, overran, read: reached.length };
}
