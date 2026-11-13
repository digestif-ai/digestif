import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import { feedThreads } from '#lib/threads.ts';
import type { PageLoad } from './$types';

/** One Feed thread (ISS-85464): every message of it the Feed holds, oldest first, read off the same feed the list threads. */
export const load: PageLoad = async ({ fetch, params }) => {
  const feed = unwrap(await createClient(fetch).feed());
  const thread = feedThreads(feed).find((t) => t.key === params.key);
  return { messages: thread?.rows ?? [] };
};
