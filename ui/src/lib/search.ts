import type { FeedItem, ItemSummary, MemberSummary, NoteSummary } from '#generated/ai-digestif-digestif-node.ts';
import { createClient, isApiError, type Client } from '#lib/api/client.ts';
import { cursorAfter } from '#lib/paging.ts';
import { href } from './href.ts';
import { feedThreads, itemThreads, type Thread } from './threads.ts';

// Global search (DIG-475): one query over the Inbox, the feed, the member's notes, the members and the
// settings pages. The node's lists answer a page at a time, so the search reads each list page by page,
// up to MAX_PAGES of PAGE_SIZE rows, and matches in the browser; a list longer than that is said to be cut.

export type SearchKind = 'inbox' | 'feed' | 'notes' | 'members' | 'settings';

export interface SearchHit {
  kind: SearchKind;
  title: string;
  /** One muted line under the title: who it is from, or what the page holds. */
  detail?: string | undefined;
  href: string;
}

export interface SearchGroup {
  kind: SearchKind;
  label: string;
  hits: SearchHit[];
}

/** The groups in the order a result page shows them. */
export const SEARCH_KINDS: { kind: SearchKind; label: string }[] = [
  { kind: 'inbox', label: 'Inbox' },
  { kind: 'feed', label: 'Feed' },
  { kind: 'notes', label: 'Notes' },
  { kind: 'members', label: 'Members' },
  { kind: 'settings', label: 'Settings' }
];

export const PAGE_SIZE = 200;
export const MAX_PAGES = 5;

/** The result page for [query]; a blank query is the page with nothing asked. */
export const searchHref = (query: string): string => '/search' + (query.trim() === '' ? '' : '?q=' + encodeURIComponent(query.trim()));

/** The words of [query], lower case; a row matches when every word is in one of its fields. */
export function words(query: string): string[] {
  return query
    .toLowerCase()
    .split(/\s+/)
    .filter((w) => w !== '');
}

export function matches(query: string, ...fields: (string | undefined)[]): boolean {
  const ws = words(query);
  if (ws.length === 0) return false;
  const text = fields.join('\n').toLowerCase();
  return ws.every((w) => text.includes(w));
}

interface SettingsPage {
  title: string;
  href: string;
  /** What the page holds, also searched. */
  about: string;
}

/** Every settings page: its title, its address and what it is for. */
export const SETTINGS_PAGES: SettingsPage[] = [
  { title: 'Names', href: href.namesEdit(), about: 'Your name and your agent name' },
  { title: 'Agent', href: href.agentEdit(), about: 'The agent that writes your notes' },
  { title: 'Inbox agent', href: href.inboxAgent(), about: 'What your agent does with everything that reaches you' },
  { title: 'Sources', href: href.sourcesEdit(), about: 'Where your notes read from' },
  { title: 'Repositories', href: href.settingsRepositories(), about: 'Organizations, repositories and commit authors' },
  { title: 'Brief', href: href.briefEdit(), about: 'What you work on' },
  { title: 'Rules', href: href.rulesEdit(), about: 'Rules for your notes, quiet hours' },
  { title: 'Quiet hours', href: href.quietHours(), about: 'When your agent stays silent' },
  { title: 'Note prompt', href: href.notePrompt(), about: "The circle's nightly note prompt and suggestions to change it" },
  { title: 'Learnings', href: href.learningsEdit(), about: 'What your notes have learned' },
  { title: 'Deny list', href: href.denyList(), about: 'Words and patterns that are never sent' },
  { title: 'Approval', href: href.approvalEdit(), about: 'Approve notes yourself or let them go out on their own' },
  { title: 'Note time', href: href.noteTimeEdit(), about: 'When the nightly note is written, and the time zone' },
  { title: 'Digest', href: href.digestEdit(), about: 'The email digest' },
  { title: 'Phones', href: href.phones(), about: 'Your paired phones' }
];

export function settingsHits(query: string): SearchHit[] {
  return SETTINGS_PAGES.filter((p) => matches(query, p.title, p.about)).map((p) => ({
    kind: 'settings',
    title: p.title,
    detail: p.about,
    href: p.href
  }));
}

/**
 * One hit per thread with a matching row, in the list's own order, as the Inbox and the Feed show a
 * thread once (ISS-85464). The hit reads as the thread's first matching row, so the words searched are
 * in what it shows; a thread of more than one row opens at its thread page, a single row at its own.
 */
function threadHits<T>(threads: Thread<T>[], isHit: (row: T) => boolean, hitOf: (row: T, thread: Thread<T>) => SearchHit): SearchHit[] {
  return threads.flatMap((t) => {
    const ordered = [t.shown, ...t.rows.filter((r) => r !== t.shown)];
    const hit = ordered.find(isHit);
    return hit === undefined ? [] : [hitOf(hit, t)];
  });
}

export function itemHits(query: string, items: ItemSummary[]): SearchHit[] {
  return threadHits(
    itemThreads(items),
    (i) => matches(query, i.title, i.author.name, i.author.agent_name),
    (i, t) => ({
      kind: 'inbox',
      title: i.title,
      detail: 'From ' + i.author.name,
      href: t.rows.length > 1 ? href.itemThread(t.key) : href.item(i.id)
    })
  );
}

export function feedHits(query: string, feed: FeedItem[]): SearchHit[] {
  return threadHits(
    feedThreads(feed),
    (f) => matches(query, f.preview, f.author.name, f.author.agent_name),
    (f, t) => ({
      kind: 'feed',
      title: f.preview,
      detail: 'From ' + f.author.name,
      href: t.rows.length > 1 ? href.feedThread(t.key) : href.message(f.hash)
    })
  );
}

export function noteHits(query: string, notes: NoteSummary[]): SearchHit[] {
  return notes
    .filter((n) => n.preview !== undefined && matches(query, n.preview))
    .map((n) => ({ kind: 'notes', title: n.preview ?? '', href: href.note(n.id) }));
}

export function memberHits(query: string, members: MemberSummary[]): SearchHit[] {
  return members
    .filter((m) => matches(query, m.name, m.agent_name))
    .map((m) => ({ kind: 'members', title: m.name, detail: m.agent_name, href: href.member(m.identity) }));
}

/** [hits] in groups, in the order of SEARCH_KINDS, a kind with no hit left out. */
export function groupHits(hits: SearchHit[]): SearchGroup[] {
  return SEARCH_KINDS.map(({ kind, label }) => ({ kind, label, hits: hits.filter((h) => h.kind === kind) })).filter(
    (g) => g.hits.length > 0
  );
}

export interface SearchResult {
  groups: SearchGroup[];
  /** The kinds the node did not answer, each with its message. */
  failed: { label: string; message: string }[];
  /** The kinds with more rows than the search reads. */
  cut: string[];
}

interface Read<T> {
  rows: T[];
  cut: boolean;
  error?: string;
}

/** Reads a list page by page until it ends or MAX_PAGES are in. */
async function readAll<T>(
  read: (cursor: string | undefined) => Promise<{ data: T[] } | { errors: { message: string }[] }>,
  idOf: (row: T) => string
): Promise<Read<T>> {
  const rows: T[] = [];
  let cursor: string | undefined;
  for (let n = 0; n < MAX_PAGES; n++) {
    const answer = await read(cursor);
    if ('errors' in answer) return { rows, cut: false, error: answer.errors.map((e) => e.message).join(' ') };
    rows.push(...answer.data);
    if (answer.data.length < PAGE_SIZE) return { rows, cut: false };
    cursor = cursorAfter(answer.data, idOf);
  }
  return { rows, cut: true };
}

/** Searches the node for [query]; a list that fails is named and the others still answer. */
export async function runSearch(query: string, client: Client = createClient()): Promise<SearchResult> {
  if (words(query).length === 0) return { groups: [], failed: [], cut: [] };
  const page = (cursor: string | undefined): { limit: number; cursor?: string } => ({
    limit: PAGE_SIZE,
    ...(cursor === undefined ? {} : { cursor })
  });
  const [items, feed, notes, members] = await Promise.all([
    readAll(
      (c) => client.items([], page(c)),
      (i) => i.id
    ),
    // The feed pages by time (before), not by id.
    readFeed(client),
    readAll(
      async (c) => {
        const r = await client.notes(page(c));
        return isApiError(r) ? r : { data: r.data.notes };
      },
      (n) => n.id
    ),
    readAll(
      (c) => client.members(page(c)),
      (m) => m.identity
    )
  ]);
  const reads: [string, Read<unknown>][] = [
    ['Inbox', items],
    ['Feed', feed],
    ['Notes', notes],
    ['Members', members]
  ];
  return {
    groups: groupHits([
      ...itemHits(query, items.rows),
      ...feedHits(query, feed.rows),
      ...noteHits(query, notes.rows),
      ...memberHits(query, members.rows),
      ...settingsHits(query)
    ]),
    failed: reads.flatMap(([label, r]) => (r.error === undefined ? [] : [{ label, message: r.error }])),
    cut: reads.filter(([, r]) => r.cut).map(([label]) => label)
  };
}

/** The node pages the feed with a strict "older than before", so rows sharing the last row's second would be skipped; the next page starts a second later and the rows already read are dropped by hash. */
export function feedCursor(createdAt: string): string {
  return new Date(Date.parse(createdAt) + 1000).toISOString();
}

export async function readFeed(client: Client): Promise<Read<FeedItem>> {
  const rows: FeedItem[] = [];
  const seen = new Set<string>();
  let before: string | undefined;
  for (let n = 0; n < MAX_PAGES; n++) {
    const answer = await client.feed({ limit: PAGE_SIZE, ...(before === undefined ? {} : { before }) });
    if (isApiError(answer)) return { rows, cut: false, error: answer.errors.map((e) => e.message).join(' ') };
    const fresh = answer.data.filter((f) => !seen.has(f.hash));
    for (const f of fresh) seen.add(f.hash);
    rows.push(...fresh);
    const last = answer.data[answer.data.length - 1];
    if (answer.data.length < PAGE_SIZE || last === undefined) return { rows, cut: false };
    // A whole page inside one second cannot be walked past.
    if (fresh.length === 0) return { rows, cut: true };
    before = feedCursor(last.created_at);
  }
  return { rows, cut: true };
}
