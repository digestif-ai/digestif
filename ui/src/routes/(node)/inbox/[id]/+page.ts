import { createClient } from '#lib/api/client.ts';
import { selfOf, unwrap } from '#lib/load.ts';
import type { PageLoad } from './$types';

/** The item, and which member is this node's (DIG-225). */
export const load: PageLoad = async ({ fetch, params, parent }) => {
  const client = createClient(fetch);
  const [item, self, { status }] = await Promise.all([client.item(params.id), selfOf(client), parent()]);
  return { item: unwrap(item), self: self?.identity, status: await status };
};
