import { createClient } from '#lib/api/client.ts';
import { selfOf, unwrap } from '#lib/load.ts';
import type { PageLoad } from './$types';

/**
 * One Inbox thread (ISS-85464): every item about one message, oldest first, read by its key on the
 * node (DIG-225) across the Inbox, Waiting on others and the Archive (ISS-88476).
 */
export const load: PageLoad = async ({ fetch, params }) => {
  const client = createClient(fetch);
  const [items, self] = await Promise.all([client.itemThread(params.key), selfOf(client)]);
  return { items: unwrap(items), self: self?.identity };
};
