import type { ItemState, ItemSummary } from '#generated/ai-digestif-digestif-node.ts';
import type { ApiResponse, Client } from './api/client.ts';
import { INBOX_FROM, type InboxFrom } from './items.ts';
import type { PageQuery } from './paging.ts';

/** Rows the Inbox shows before More (DIG-474). */
export const INBOX_PAGE = 25;

/** The Inbox's filters (DIG-476, ISS-88476, DIG-128): the view, none being the Inbox itself, and whose words, none being everyone's. */
export interface InboxFilter {
  state: ItemState | undefined;
  from: InboxFrom | undefined;
}

/**
 * The page of the member's items [query] asks for, in the view and voices [filter] names, read in one
 * request: the node filters both, since only it knows who acts next on an item (ISS-86956). The first
 * page and every More read through here, so they apply the same filters (DIG-474, DIG-128).
 */
export async function readInbox(client: Pick<Client, 'items'>, filter: InboxFilter, query: PageQuery): Promise<ApiResponse<ItemSummary[]>> {
  const voices = INBOX_FROM.find((f) => f.from === filter.from)?.voices;
  return client.items([], query, {
    ...(filter.state === undefined ? {} : { states: [filter.state] }),
    ...(voices === undefined ? {} : { voices })
  });
}
