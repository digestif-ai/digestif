import { ItemStatus } from '#generated/com-bryzek-digestif-node.ts';
import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import { pageOf, pageQuery } from '#lib/paging.ts';
import type { PageLoad } from './$types';

/** The first page of the member's items, in the status the filter names; More reads the rest (ISS-41988). */
export const load: PageLoad = async ({ fetch, url }) => {
  const named = url.searchParams.get('status');
  const status = Object.values(ItemStatus).find((s) => s === named);
  return { status, items: pageOf(unwrap(await createClient(fetch).items(status, pageQuery()))) };
};
