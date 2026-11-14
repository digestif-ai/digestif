import type { ItemState, ItemSummary } from '#generated/ai-digestif-digestif-node.ts';
import type { ApiResponse, Client } from './api/client.ts';
import { kindQuery } from './items.ts';
import type { PageQuery } from './paging.ts';

/** Rows the Inbox shows before More (DIG-474). */
export const INBOX_PAGE = 25;

/** The Inbox's filters (DIG-476, ISS-88476): the view, none being the Inbox itself, and the kinds checked; no kind checked means every kind. */
export interface InboxFilter {
  state: ItemState | undefined;
  kinds: string[];
}

/**
 * The page of the member's items [query] asks for, in the states and kinds [filter] names, read in one
 * request: the node filters both, since only it knows who acts next on an item (ISS-86956). The first
 * page and every More read through here, so they apply the same filters (DIG-474, DIG-476).
 */
export async function readInbox(client: Pick<Client, 'items'>, filter: InboxFilter, query: PageQuery): Promise<ApiResponse<ItemSummary[]>> {
  return client.items([], query, {
    ...(filter.state === undefined ? {} : { states: [filter.state] }),
    ...(filter.kinds.length === 0 ? {} : kindQuery(filter.kinds))
  });
}
