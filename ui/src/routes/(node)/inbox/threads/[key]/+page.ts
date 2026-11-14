import { ItemState } from '#generated/ai-digestif-digestif-node.ts';
import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import { itemThreadKey } from '#lib/threads.ts';
import type { PageLoad } from './$types';

/**
 * One Inbox thread (ISS-85464): every item about one message, oldest first. The Inbox, Waiting on others
 * and the Archive together are every item the member has (ISS-88476), read in two requests.
 */
export const load: PageLoad = async ({ fetch, params }) => {
  const client = createClient(fetch);
  const [inbox, rest, members] = await Promise.all([
    client.items([], { limit: 200 }),
    client.items([], { limit: 200 }, { states: [ItemState.Others, ItemState.Archived] }),
    client.members({ limit: 200 })
  ]);
  const byId = new Map([...unwrap(inbox), ...unwrap(rest)].map((i) => [i.id, i]));
  return {
    items: [...byId.values()].filter((i) => itemThreadKey(i) === params.key).sort((a, b) => a.created_at.localeCompare(b.created_at)),
    self: unwrap(members).find((m) => m.is_self)?.identity
  };
};
