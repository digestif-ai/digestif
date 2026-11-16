import { ItemKind, ItemState, ItemStatus, Voice, type ItemSummary } from '#generated/ai-digestif-digestif-node.ts';
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

describe('readInbox (DIG-474, DIG-476, ISS-86956, ISS-88476)', () => {
  it('reads one page of the Inbox itself, no view named, for the node to filter', async () => {
    const n = node([item('a'), item('c', { author: me })]);
    expect(ids(await readInbox(n, { state: undefined, from: undefined }, { limit: 26, cursor: 'z' }))).toEqual(['a', 'c']);
    expect(n.asked).toEqual([{ statuses: [], page: { limit: 26, cursor: 'z' }, filter: {} }]);
  });

  it('asks for the view and the voices the From names (DIG-128)', async () => {
    const n = node([]);
    await readInbox(n, { state: ItemState.Archived, from: 'agents' }, { limit: 26 });
    await readInbox(n, { state: undefined, from: 'people' }, { limit: 26 });
    expect(n.asked.map((a) => a.filter)).toEqual([
      { states: [ItemState.Archived], voices: [Voice.Agent, Voice.Node] },
      { voices: [Voice.Person] }
    ]);
  });
});

describe('href.inbox', () => {
  it('is the bare Inbox by default and names the view and From when given', () => {
    expect(href.inbox()).toBe('/inbox');
    expect(href.inbox({ state: undefined, from: undefined })).toBe('/inbox');
    expect(href.inbox({ state: 'others', from: 'people' })).toBe('/inbox?state=others&from=people');
  });
});
