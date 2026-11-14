import { ItemKind, ItemStatus, Voice, type ItemSummary } from '#generated/ai-digestif-digestif-node.ts';
import { describe, expect, it } from 'vitest';
import type { ApiResponse } from './api/client.ts';
import { href } from './href.ts';
import { readInbox } from './inbox.ts';
import type { PageQuery } from './paging.ts';

const me = { identity: 'ed25519:me', name: 'Me', agent_name: 'Juno' };
const ben = { identity: 'ed25519:ben', name: 'Ben Ortiz', agent_name: 'Otis' };

function item(id: string, over: Partial<ItemSummary> = {}): ItemSummary {
  return {
    id,
    kind: ItemKind.Notice,
    voice: Voice.Person,
    author: ben,
    status: ItemStatus.New,
    closed: false,
    title: id,
    created_at: '2026-11-12T12:00:00.000Z',
    ...over
  } as ItemSummary;
}

/** A node holding [all], answering by status and cursor as the real one does; it records the statuses it was asked for. */
function node(all: ItemSummary[]) {
  const asked: ItemStatus[][] = [];
  return {
    asked,
    items: (statuses: ItemStatus[], page?: PageQuery): Promise<ApiResponse<ItemSummary[]>> => {
      asked.push(statuses);
      const held = all.filter((x) => statuses.includes(x.status));
      const from = page?.cursor === undefined ? 0 : held.findIndex((x) => x.id === page.cursor) + 1;
      return Promise.resolve({ data: held.slice(from, from + (page?.limit ?? held.length)), status: 200 });
    }
  };
}

const ids = (r: ApiResponse<ItemSummary[]>): string[] => ('data' in r ? r.data.map((x) => x.id) : ['error']);

describe('readInbox (DIG-474, DIG-476)', () => {
  it('reads no Done item unless Done is checked, and keeps what waits on others only when that is checked', async () => {
    const all = [
      item('a'),
      item('b', { status: ItemStatus.Done }),
      item('c', { author: me, status: ItemStatus.Read }),
      item('d', { closed: true, status: ItemStatus.Read })
    ];
    const n = node(all);
    expect(ids(await readInbox(n, { states: ['you', 'others'], kinds: [], self: me.identity }, { limit: 10 }))).toEqual(['a', 'c']);
    expect(n.asked[0]).not.toContain(ItemStatus.Done);
    expect(ids(await readInbox(n, { states: ['you'], kinds: [], self: me.identity }, { limit: 10 }))).toEqual(['a']);
    expect(ids(await readInbox(n, { states: ['done'], kinds: [], self: me.identity }, { limit: 10 }))).toEqual(['b', 'd']);
    expect(n.asked[2]).toContain(ItemStatus.Done);
  });

  it('keeps only the kinds checked, reading on past rows that do not pass to fill the page', async () => {
    const all = Array.from({ length: 250 }, (_, i) => item('n' + String(i).padStart(3, '0'), i >= 230 ? { kind: ItemKind.Question } : {}));
    const n = node(all);
    const filter = { states: ['you' as const], kinds: ['Question'], self: me.identity };
    const first = await readInbox(n, filter, { limit: 5 });
    expect(ids(first)).toEqual(['n230', 'n231', 'n232', 'n233', 'n234']);
    // The next page reads after the last row shown, through the same filter.
    expect(ids(await readInbox(n, filter, { limit: 30, cursor: 'n234' }))).toHaveLength(15);
  });

  it('reads nothing when no state is checked', async () => {
    const n = node([item('a')]);
    expect(ids(await readInbox(n, { states: [], kinds: [], self: undefined }, { limit: 10 }))).toEqual([]);
    expect(n.asked).toHaveLength(0);
  });
});

describe('href.inbox', () => {
  it('is the bare Inbox by default and names only states and kinds that differ', () => {
    expect(href.inbox()).toBe('/inbox');
    expect(href.inbox({ states: ['you', 'others'], kinds: [] })).toBe('/inbox');
    expect(href.inbox({ states: ['you', 'others', 'done'], kinds: ['Question'] })).toBe(
      '/inbox?state=you&state=others&state=done&kind=Question'
    );
    expect(href.inbox({ states: [] })).toBe('/inbox?state=');
  });
});
