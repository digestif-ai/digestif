import { ItemKind, ItemState, ItemStatus, ItemSubject, Voice, type ItemSummary } from '#generated/ai-digestif-digestif-node.ts';
import { describe, expect, it } from 'vitest';
import type { ApiResponse, ItemFilter } from './api/client.ts';
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

/** A node that records what it was asked and answers [rows]. */
function node(rows: ItemSummary[]) {
  const asked: { statuses: ItemStatus[]; page: PageQuery | undefined; filter: ItemFilter | undefined }[] = [];
  return {
    asked,
    items: (statuses: ItemStatus[], page?: PageQuery, filter?: ItemFilter): Promise<ApiResponse<ItemSummary[]>> => {
      asked.push({ statuses, page, filter });
      return Promise.resolve({ data: rows, status: 200 });
    }
  };
}

const ids = (r: ApiResponse<ItemSummary[]>): string[] => ('data' in r ? r.data.map((x) => x.id) : ['error']);

describe('readInbox (DIG-474, DIG-476, ISS-86956)', () => {
  it('reads one page, with the states checked and every status, for the node to filter', async () => {
    const n = node([item('a'), item('c', { author: me })]);
    const filter = { states: [ItemState.You, ItemState.Others], kinds: [] };
    expect(ids(await readInbox(n, filter, { limit: 26, cursor: 'z' }))).toEqual(['a', 'c']);
    expect(n.asked).toEqual([{ statuses: [], page: { limit: 26, cursor: 'z' }, filter: { states: [ItemState.You, ItemState.Others] } }]);
  });

  it('asks for the kinds and subjects each checked kind names', async () => {
    const n = node([]);
    await readInbox(n, { states: [ItemState.Done], kinds: ['Question', 'Intro'] }, { limit: 26 });
    expect(n.asked[0]?.filter).toEqual({
      states: [ItemState.Done],
      kinds: [ItemKind.Question],
      subjects: [ItemSubject.NoteQuestion, ItemSubject.Intro]
    });
  });

  it('reads nothing when no state is checked', async () => {
    const n = node([item('a')]);
    expect(ids(await readInbox(n, { states: [], kinds: [] }, { limit: 10 }))).toEqual([]);
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
