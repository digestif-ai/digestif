import { ItemStatus, type ItemSummary } from '#generated/com-bryzek-digestif-node.ts';
import { isApiError, type ApiResponse, type Client } from './api/client.ts';
import { itemKind, itemState, type ItemState } from './items.ts';
import { pageQuery, type PageQuery } from './paging.ts';

/** Rows read from the node at a time while filling a page. */
const CHUNK = 100;

/** The Inbox's filters (DIG-476): the states and kinds checked; no kind checked means every kind. */
export interface InboxFilter {
  states: ItemState[];
  kinds: string[];
  self: string | undefined;
}

/**
 * The page of the member's items [query] asks for, in the states and kinds [filter] names. The node
 * filters by status only, so Done is read only when that state is checked, and state and kind are read
 * from each row; a page is filled from as many reads as it takes. The first page and every More read
 * through here, so they apply the same filters (DIG-474, DIG-476).
 */
export async function readInbox(client: Pick<Client, 'items'>, filter: InboxFilter, query: PageQuery): Promise<ApiResponse<ItemSummary[]>> {
  const { states, kinds, self } = filter;
  const statuses = states.includes('done')
    ? [ItemStatus.Draft, ItemStatus.New, ItemStatus.Read, ItemStatus.Done]
    : [ItemStatus.Draft, ItemStatus.New, ItemStatus.Read];
  const wanted = (x: ItemSummary): boolean => states.includes(itemState(x, self)) && (kinds.length === 0 || kinds.includes(itemKind(x)));
  const rows: ItemSummary[] = [];
  let cursor = query.cursor;
  let status = 200;
  while (states.length > 0 && rows.length < query.limit) {
    const response = await client.items(statuses, pageQuery(cursor, CHUNK));
    if (isApiError(response)) return response;
    status = response.status;
    const chunk = response.data.slice(0, CHUNK);
    rows.push(...chunk.filter(wanted));
    if (response.data.length <= CHUNK) break;
    cursor = chunk[chunk.length - 1]?.id;
  }
  return { data: rows.slice(0, query.limit), status };
}
