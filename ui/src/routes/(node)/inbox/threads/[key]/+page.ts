import { createClient } from '#lib/api/client.ts';
import { ITEM_STATUSES } from '#lib/items.ts';
import { unwrap } from '#lib/load.ts';
import { itemThreadKey } from '#lib/threads.ts';
import type { PageLoad } from './$types';

/** One Inbox thread (ISS-85464): every item about one message, in every status, oldest first. */
export const load: PageLoad = async ({ fetch, params }) => {
  const client = createClient(fetch);
  const [items, members] = await Promise.all([client.items(ITEM_STATUSES, { limit: 200 }), client.members({ limit: 200 })]);
  return {
    items: unwrap(items)
      .filter((i) => itemThreadKey(i) === params.key)
      .sort((a, b) => a.created_at.localeCompare(b.created_at)),
    self: unwrap(members).find((m) => m.is_self)?.identity
  };
};
