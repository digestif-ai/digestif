import { createClient } from '#lib/api/client.ts';
import { filterStatuses, inboxFilter } from '#lib/items.ts';
import { unwrap } from '#lib/load.ts';
import { pageOf, pageQuery } from '#lib/paging.ts';
import type { PageLoad } from './$types';

/**
 * The first page of the member's items, in the statuses the filter names, every one but Done unless it
 * names another (ISS-71225); More reads the rest (ISS-41988).
 * The circle says which member is this node's, for the From column (the circle is small, so one page holds it).
 */
export const load: PageLoad = async ({ fetch, url }) => {
  const filter = inboxFilter(url.searchParams.get('status'));
  const client = createClient(fetch);
  const [items, members] = await Promise.all([client.items(filterStatuses(filter), pageQuery()), client.members({ limit: 200 })]);
  return { filter, items: pageOf(unwrap(items)), self: unwrap(members).find((m) => m.is_self)?.identity };
};
