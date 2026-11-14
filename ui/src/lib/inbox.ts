import type { ItemState, ItemSummary } from '#generated/ai-digestif-digestif-node.ts';
import type { ApiResponse, Client } from './api/client.ts';
import { kindQuery } from './items.ts';
import type { PageQuery } from './paging.ts';

/** Rows the Inbox shows before More (DIG-474). */
export const INBOX_PAGE = 25;

/** The Inbox's filters (DIG-476): the states and kinds checked; no kind checked means every kind. */
export interface InboxFilter {
  states: ItemState[];
  kinds: string[];
}

/**
 * The page of the member's items [query] asks for, in the states and kinds [filter] names, read in one
 * request: the node filters both, since only it knows who acts next on an item (ISS-86956). The first
 * page and every More read through here, so they apply the same filters (DIG-474, DIG-476).
 */
export async function readInbox(client: Pick<Client, 'items'>, filter: InboxFilter, query: PageQuery): Promise<ApiResponse<ItemSummary[]>> {
  if (filter.states.length === 0) return { data: [], status: 200 };
  return client.items([], query, { states: filter.states, ...(filter.kinds.length === 0 ? {} : kindQuery(filter.kinds)) });
}
