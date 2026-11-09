import { ItemStatus } from '#generated/com-bryzek-digestif-node.ts';
import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import { pageOf, pageQuery } from '#lib/paging.ts';
import type { PageLoad } from './$types';

/**
 * The first page of the member's items, in the status the filter names; More reads the rest (ISS-41988).
 * The circle says which member is this node's, for the From column (the circle is small, so one page holds it).
 */
export const load: PageLoad = async ({ fetch, url }) => {
  const named = url.searchParams.get('status');
  const status = Object.values(ItemStatus).find((s) => s === named);
  const client = createClient(fetch);
  const [items, members] = await Promise.all([client.items(status, pageQuery()), client.members({ limit: 200 })]);
  return { status, items: pageOf(unwrap(items)), self: unwrap(members).find((m) => m.is_self)?.identity };
};
