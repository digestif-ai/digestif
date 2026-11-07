import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import type { PageLoad } from './$types';

/** The item, and the circle, which says which member is this node's (the circle is small, so one page holds it). */
export const load: PageLoad = async ({ fetch, params }) => {
  const client = createClient(fetch);
  const [item, members] = await Promise.all([client.item(params.id), client.members({ limit: 200 })]);
  return { item: unwrap(item), self: unwrap(members).find((m) => m.is_self)?.identity };
};
