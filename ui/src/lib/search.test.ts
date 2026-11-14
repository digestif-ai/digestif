import { readdirSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import {
  MessageStatus,
  StatusNote,
  Voice,
  type FeedItem,
  type ItemSummary,
  type MemberSummary
} from '#generated/ai-digestif-digestif-node.ts';
import {
  feedHits,
  groupHits,
  itemHits,
  matches,
  memberHits,
  runSearch,
  searchHref,
  settingsHits,
  words,
  readFeed,
  SETTINGS_PAGES,
  MAX_PAGES,
  PAGE_SIZE
} from './search.ts';
import type { Client } from '#lib/api/client.ts';

const author = { identity: 'ed25519:a', name: 'Ben Ortiz', agent_name: 'Juno' };
const item = (id: string, title: string): ItemSummary => ({ id, title, author }) as unknown as ItemSummary;
const member = (name: string): MemberSummary => ({ identity: 'ed25519:' + name, name, agent_name: 'Hermes' }) as unknown as MemberSummary;

describe('matching', () => {
  it('needs every word, in any field, in any case', () => {
    expect(words('  Eval  SETS ')).toEqual(['eval', 'sets']);
    expect(matches('eval ben', 'Keep eval sets clean', 'Ben Ortiz')).toBe(true);
    expect(matches('eval zed', 'Keep eval sets clean', 'Ben Ortiz')).toBe(false);
    expect(matches('   ', 'anything')).toBe(false);
  });
});

describe('hits', () => {
  it('link an item, a member and a settings page to their pages', () => {
    expect(itemHits('eval', [item('i1', 'Eval sets'), item('i2', 'Relay')])).toEqual([
      { kind: 'inbox', title: 'Eval sets', detail: 'From Ben Ortiz', href: '/inbox/i1' }
    ]);
    expect(memberHits('ada', [member('Ada Park'), member('Cy Lund')]).map((h) => h.href)).toEqual(['/members/ed25519%3AAda%20Park']);
    expect(settingsHits('quiet').map((h) => h.href)).toContain('/settings/quiet-hours');
    expect(settingsHits('zzzz')).toEqual([]);
  });

  it('groups in the page order and leaves empty kinds out', () => {
    const groups = groupHits([...settingsHits('names'), ...memberHits('ben', [member('Ben Ortiz')]), ...itemHits('x', [item('1', 'x')])]);
    expect(groups.map((g) => g.kind)).toEqual(['inbox', 'members', 'settings']);
  });

  it('builds the result address', () => {
    expect(searchHref(' a b ')).toBe('/search?q=a%20b');
    expect(searchHref('  ')).toBe('/search');
  });
});

describe('threads', () => {
  const message = (hash: string, day: number, preview: string, over: Partial<FeedItem> = {}): FeedItem => ({
    hash,
    kind: 'summary',
    voice: Voice.Agent,
    author,
    created_at: `2026-11-${String(day).padStart(2, '0')}T21:00:00.000Z`,
    status: MessageStatus.Posted,
    preview,
    ...over
  });

  it('shows a two-row Feed thread once, opening at its thread page', () => {
    // Newest first, as the Feed reads: the note that went out after a waiting-for-approval status note.
    const feed = [
      message('note', 14, 'Shipped the relay fix'),
      message('wait', 13, 'No note from Ben today: waiting on the relay fix', { status_note: StatusNote.WaitingForApproval }),
      message('other', 12, 'Relay load test')
    ];
    expect(feedHits('relay fix', feed)).toEqual([
      { kind: 'feed', title: 'Shipped the relay fix', detail: 'From Ben Ortiz', href: '/feed/threads/note' }
    ]);
    // The hit reads as the row that matched, and a thread of one opens at its own page.
    expect(feedHits('waiting', feed).map((h) => [h.title, h.href])).toEqual([
      ['No note from Ben today: waiting on the relay fix', '/feed/threads/note']
    ]);
    expect(feedHits('load', feed).map((h) => h.href)).toEqual(['/feed/other']);
  });

  it('shows a two-row Inbox thread once, opening at its thread page', () => {
    const about = (id: string, title: string, day: number): ItemSummary =>
      ({ ...item(id, title), about: 'note', created_at: `2026-11-${String(day).padStart(2, '0')}T21:00:00.000Z` }) as ItemSummary;
    const items = [about('i2', 'Relay fix follow-up', 14), about('i1', 'Relay fix question', 13), item('i3', 'Relay elsewhere')];
    expect(itemHits('relay fix', items)).toEqual([
      { kind: 'inbox', title: 'Relay fix follow-up', detail: 'From Ben Ortiz', href: '/inbox/threads/note' }
    ]);
    expect(itemHits('question', items).map((h) => h.href)).toEqual(['/inbox/threads/note']);
    expect(itemHits('elsewhere', items).map((h) => h.href)).toEqual(['/inbox/i3']);
  });
});

describe('runSearch', () => {
  const ok = <T>(data: T) => Promise.resolve({ data, status: 200 });
  it('reads every page of a long list, then says when it stops at the cap', async () => {
    const full = (n: number): ItemSummary[] => Array.from({ length: PAGE_SIZE }, (_, i) => item('r' + String(n) + '-' + String(i), 'row'));
    let calls = 0;
    const client = {
      items: () => ok(full(calls++)),
      feed: () => ok([]),
      notes: () => ok({ notes: [], suggest_auto_approval: false, no_activity: false }),
      members: () => ok([member('Ada Park')])
    } as unknown as Client;
    const result = await runSearch('row', client);
    expect(calls).toBe(MAX_PAGES);
    expect(result.cut).toEqual(['Inbox']);
    expect(result.groups[0]?.hits).toHaveLength(MAX_PAGES * PAGE_SIZE);
  });

  it('names a list that failed and still answers with the others', async () => {
    const client = {
      items: () => Promise.resolve({ errors: [{ code: 'x', message: 'Down.' }], status: 500 }),
      feed: () => ok([]),
      notes: () => ok({ notes: [], suggest_auto_approval: false, no_activity: false }),
      members: () => ok([member('Ada Park')])
    } as unknown as Client;
    const result = await runSearch('ada', client);
    expect(result.failed).toEqual([{ label: 'Inbox', message: 'Down.' }]);
    expect(result.groups.map((g) => g.kind)).toEqual(['members']);
  });

  it('asks nothing for a blank query', async () => {
    expect(await runSearch('  ', {} as Client)).toEqual({ groups: [], failed: [], cut: [] });
  });
});

describe('the feed across a page boundary', () => {
  it("keeps rows that share the last row's timestamp, as the node pages with a strict before", async () => {
    const at = (i: number): string => new Date(Date.UTC(2026, 0, 1) - Math.min(i, PAGE_SIZE - 1) * 10_000).toISOString();
    // 201 rows: the 200th and 201st share a second, so the first page ends between them.
    const all = Array.from(
      { length: PAGE_SIZE + 1 },
      (_, i) => ({ hash: 'h' + String(i), created_at: at(i), preview: 'row', author }) as unknown as FeedItem
    );
    const client = {
      feed: (q: { limit: number; before?: string }) =>
        Promise.resolve({
          data: all.filter((f) => q.before === undefined || Date.parse(f.created_at) < Date.parse(q.before)).slice(0, q.limit),
          status: 200
        })
    } as unknown as Client;
    const read = await readFeed(client);
    expect(read.rows.map((f) => f.hash)).toEqual(all.map((f) => f.hash));
    expect(read.cut).toBe(false);
  });
});

describe('settings pages', () => {
  it('lists every folder under routes/(node)/settings', () => {
    const folders = readdirSync(new URL('../routes/(node)/settings', import.meta.url), { withFileTypes: true })
      .filter((d) => d.isDirectory())
      .map((d) => d.name);
    expect(folders.length).toBeGreaterThan(10);
    for (const f of folders)
      expect(
        SETTINGS_PAGES.some((p) => p.href.startsWith('/settings/' + f)),
        f
      ).toBe(true);
  });
});
