import { createClient } from '#lib/api/client.ts';
import { ItemStatus, type ItemSummary } from '#generated/com-bryzek-digestif-node.ts';
import { checkedKinds, checkedStates, itemKind, itemState } from '#lib/items.ts';
import { unwrap } from '#lib/load.ts';
import { pageQuery } from '#lib/paging.ts';
import type { PageLoad } from './$types';

/** Rows a page shows (DIG-474). */
const INBOX_PAGE = 25;
/** Rows read from the node at a time while filling a page. */
const CHUNK = 100;

/**
 * One page of the member's items in the states and kinds the filters name, Waiting on you and Waiting on
 * others unless it names another (DIG-476). The node filters by status only, so state and kind are read
 * from each row and a page is filled from as many reads as it takes. `after` holds the id of the last row
 * of each page before this one, so Newer and Older are plain links (DIG-474).
 * The circle says which member is this node's, for the From column (the circle is small, so one page holds it).
 */
export const load: PageLoad = async ({ fetch, url }) => {
  const states = checkedStates(url.searchParams);
  const kinds = checkedKinds(url.searchParams);
  const after = url.searchParams.getAll('after');
  const client = createClient(fetch);
  const members = unwrap(await client.members({ limit: 200 }));
  const self = members.find((m) => m.is_self)?.identity;
  const statuses = states.includes('done')
    ? [ItemStatus.Draft, ItemStatus.New, ItemStatus.Read, ItemStatus.Done]
    : [ItemStatus.Draft, ItemStatus.New, ItemStatus.Read];
  const wanted = (x: ItemSummary): boolean => states.includes(itemState(x, self)) && (kinds.length === 0 || kinds.includes(itemKind(x)));

  const rows: ItemSummary[] = [];
  let more = false;
  let cursor = after[after.length - 1];
  while (states.length > 0 && rows.length <= INBOX_PAGE) {
    const read = unwrap(await client.items(statuses, pageQuery(cursor, CHUNK)));
    const chunk = read.slice(0, CHUNK);
    for (const x of chunk) {
      if (!wanted(x)) continue;
      if (rows.length === INBOX_PAGE) {
        more = true;
        break;
      }
      rows.push(x);
    }
    if (more || read.length <= CHUNK) break;
    cursor = chunk[chunk.length - 1]?.id;
  }
  return { states, kinds, after, rows, more, self };
};
