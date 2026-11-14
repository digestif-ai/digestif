import { readdirSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import {
  MessageStatus,
  StatusNote,
  Voice,
  type FeedItem,
  type ItemSummary,
  type MemberSummary,
  type SearchResults
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
  SETTINGS_PAGES,
  LIMIT
} from './search.ts';
import type { Client } from '#lib/api/client.ts';

const author = { identity: 'ed25519:a', name: 'Ben Ortiz', agent_name: 'Juno' };
const item = (id: string, title: string): ItemSummary => ({ id, title, author }) as unknown as ItemSummary;
const member = (name: string): MemberSummary => ({ identity: 'ed25519:' + name, name, agent_name: 'Hermes' }) as unknown as MemberSummary;
const message = (hash: string, preview: string): FeedItem => ({ hash, preview, author }) as unknown as FeedItem;
const empty: SearchResults = { inbox: [], feed: [], notes: [], members: [] };

describe('matching', () => {
  it('needs every word, in any field, in any case', () => {
    expect(words('  Eval  SETS ')).toEqual(['eval', 'sets']);
    expect(matches('eval ben', 'Keep eval sets clean', 'Ben Ortiz')).toBe(true);
    expect(matches('eval zed', 'Keep eval sets clean', 'Ben Ortiz')).toBe(false);
    expect(matches('   ', 'anything')).toBe(false);
  });
});

describe('hits', () => {
  it('link an item, a message, a member and a settings page to their pages', () => {
    expect(itemHits([item('i1', 'Eval sets')])).toEqual([
      { kind: 'inbox', title: 'Eval sets', detail: 'From Ben Ortiz', href: '/inbox/i1' }
    ]);
    expect(feedHits([message('sha256:1', 'A note')]).map((h) => h.title)).toEqual(['A note']);
    expect(memberHits([member('Ada Park')]).map((h) => h.href)).toEqual(['/members/ed25519%3AAda%20Park']);
    expect(settingsHits('quiet').map((h) => h.href)).toContain('/settings/quiet-hours');
    expect(settingsHits('zzzz')).toEqual([]);
  });

  it('groups in the page order and leaves empty kinds out', () => {
    const groups = groupHits([...settingsHits('names'), ...memberHits([member('Ben Ortiz')]), ...itemHits([item('1', 'x')])]);
    expect(groups.map((g) => g.kind)).toEqual(['inbox', 'members', 'settings']);
  });

  it('builds the result address', () => {
    expect(searchHref(' a b ')).toBe('/search?q=a%20b');
    expect(searchHref('  ')).toBe('/search');
  });
});

describe('threads', () => {
  const at = (day: number): string => `2026-11-${String(day).padStart(2, '0')}T21:00:00.000Z`;
  const row = (hash: string, day: number, preview: string, over: Partial<FeedItem> = {}): FeedItem => ({
    hash,
    kind: 'summary',
    voice: Voice.Agent,
    author,
    created_at: at(day),
    status: MessageStatus.Posted,
    preview,
    ...over
  });

  it('shows a Feed thread whose rows matched once, opening at its thread page', () => {
    // The node's hits: the note that went out after a waiting-for-approval status note, both matching.
    const hits = [
      row('note', 14, 'Shipped the relay fix'),
      row('wait', 13, 'No note from Ben today: waiting on the relay fix', { status_note: StatusNote.WaitingForApproval }),
      row('other', 12, 'Relay load test')
    ];
    expect(feedHits(hits).map((h) => [h.title, h.href])).toEqual([
      ['Shipped the relay fix', '/feed/threads/note'],
      ['Relay load test', '/feed/other']
    ]);
    // One matching row of a thread opens at its own page, which every message has however old it is.
    expect(feedHits([hits[1]!]).map((h) => [h.title, h.href])).toEqual([
      ['No note from Ben today: waiting on the relay fix', '/feed/wait']
    ]);
  });

  it('shows an Inbox thread whose rows matched once, opening at its thread page', () => {
    const about = (id: string, title: string, day: number): ItemSummary =>
      ({ ...item(id, title), about: 'note', created_at: at(day) }) as ItemSummary;
    const hits = [about('i2', 'Relay fix follow-up', 14), about('i1', 'Relay fix question', 13), item('i3', 'Relay elsewhere')];
    expect(itemHits(hits).map((h) => [h.title, h.href])).toEqual([
      ['Relay fix follow-up', '/inbox/threads/note'],
      ['Relay elsewhere', '/inbox/i3']
    ]);
    expect(itemHits([hits[1]!]).map((h) => h.href)).toEqual(['/inbox/i1']);
  });
});

describe('runSearch', () => {
  it('asks the node once and shows what it found beside the settings pages', async () => {
    const asked: [string, number][] = [];
    const client = {
      search: (q: string, limit: number) => {
        asked.push([q, limit]);
        return Promise.resolve({
          data: { ...empty, inbox: [item('i1', 'Quiet relays')], feed: [message('sha256:1', 'Hours')] },
          status: 200
        });
      }
    } as unknown as Client;
    const result = await runSearch(' quiet ', client);
    expect(asked).toEqual([['quiet', LIMIT]]);
    expect(result.failed).toBeUndefined();
    expect(result.groups.map((g) => g.kind)).toEqual(['inbox', 'feed', 'settings']);
  });

  it('names a node that failed and still answers with the settings pages', async () => {
    const client = {
      search: () => Promise.resolve({ errors: [{ code: 'x', message: 'Down.' }], status: 500 })
    } as unknown as Client;
    const result = await runSearch('quiet', client);
    expect(result.failed).toBe('Down.');
    expect(result.groups.map((g) => g.kind)).toEqual(['settings']);
  });

  it('asks nothing for a blank query', async () => {
    expect(await runSearch('  ', {} as Client)).toEqual({ groups: [] });
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
