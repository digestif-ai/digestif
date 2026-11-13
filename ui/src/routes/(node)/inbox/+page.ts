import { createClient } from '#lib/api/client.ts';
import { readInbox } from '#lib/inbox.ts';
import { checkedKinds, checkedStates } from '#lib/items.ts';
import { unwrap } from '#lib/load.ts';
import { pageOf, pageQuery } from '#lib/paging.ts';
import type { PageLoad } from './$types';

/**
 * The first page of the member's items in the states and kinds the filters name, Waiting on you and
 * Waiting on others unless it names another (DIG-476); More reads the rest through the same filters
 * (ISS-41988). The circle says which member is this node's, for the From column and the states (the
 * circle is small, so one page holds it).
 */
export const load: PageLoad = async ({ fetch, url }) => {
  const states = checkedStates(url.searchParams);
  const kinds = checkedKinds(url.searchParams);
  const client = createClient(fetch);
  const self = unwrap(await client.members({ limit: 200 })).find((m) => m.is_self)?.identity;
  const items = unwrap(await readInbox(client, { states, kinds, self }, pageQuery()));
  return { states, kinds, self, items: pageOf(items) };
};
