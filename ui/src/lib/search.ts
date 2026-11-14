import type { FeedItem, ItemSummary, MemberSummary, NoteSummary } from '#generated/ai-digestif-digestif-node.ts';
import { createClient, isApiError, type Client } from '#lib/api/client.ts';
import { href } from './href.ts';
import { feedThreads, itemThreads, type Thread } from './threads.ts';

// Global search (DIG-475): one query over the Inbox, the feed, the member's notes, the members and the
// settings pages. The node answers the first four from the full text it holds, in one call (GET /search,
// ISS-86960); the settings pages are the UI's own and are matched here.

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

/** At most this many hits of each kind the node answers. */
export const LIMIT = 50;

/** The result page for [query]; a blank query is the page with nothing asked. */
export const searchHref = (query: string): string => '/search' + (query.trim() === '' ? '' : '?q=' + encodeURIComponent(query.trim()));

/** The words of [query], lower case; a settings page matches when every word is in its title or what it holds. */
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
 * One hit per thread, in the node's order, as the Inbox and the Feed show a thread once (ISS-85464).
 * The node answers only the rows that match, so a thread is read off the hits: the hit reads as the
 * thread's first matching row, and opens at the thread page when more than one of its rows matched,
 * else at that row's own page, which every row has however old it is.
 */
function threadHits<T>(threads: Thread<T>[], hitOf: (row: T, thread: Thread<T>) => SearchHit): SearchHit[] {
  return threads.map((t) => hitOf(t.shown, t));
}

// The node's hits, each already a match, as rows of the result page.

export function itemHits(items: ItemSummary[]): SearchHit[] {
  return threadHits(itemThreads(items), (i, t) => ({
    kind: 'inbox',
    title: i.title,
    detail: 'From ' + i.author.name,
    href: t.rows.length > 1 ? href.itemThread(t.key) : href.item(i.id)
  }));
}

export function feedHits(feed: FeedItem[]): SearchHit[] {
  return threadHits(feedThreads(feed), (f, t) => ({
    kind: 'feed',
    title: f.preview,
    detail: 'From ' + f.author.name,
    href: t.rows.length > 1 ? href.feedThread(t.key) : href.message(f.hash)
  }));
}

export function noteHits(notes: NoteSummary[]): SearchHit[] {
  return notes.map((n) => ({ kind: 'notes', title: n.preview ?? '', href: href.note(n.id) }));
}

export function memberHits(members: MemberSummary[]): SearchHit[] {
  return members.map((m) => ({ kind: 'members', title: m.name, detail: m.agent_name, href: href.member(m.identity) }));
}

/** [hits] in groups, in the order of SEARCH_KINDS, a kind with no hit left out. */
export function groupHits(hits: SearchHit[]): SearchGroup[] {
  return SEARCH_KINDS.map(({ kind, label }) => ({ kind, label, hits: hits.filter((h) => h.kind === kind) })).filter(
    (g) => g.hits.length > 0
  );
}

export interface SearchResult {
  groups: SearchGroup[];
  /** The node's message when it did not answer; the settings pages still do. */
  failed?: string | undefined;
}

/** Searches the node for [query]; a node that fails is named and the settings pages still answer. */
export async function runSearch(query: string, client: Client = createClient()): Promise<SearchResult> {
  if (words(query).length === 0) return { groups: [] };
  const answer = await client.search(query.trim(), LIMIT);
  const settings = settingsHits(query);
  if (isApiError(answer)) return { groups: groupHits(settings), failed: answer.errors.map((e) => e.message).join(' ') };
  const r = answer.data;
  return {
    groups: groupHits([...itemHits(r.inbox), ...feedHits(r.feed), ...noteHits(r.notes), ...memberHits(r.members), ...settings])
  };
}
