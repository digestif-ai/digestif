import { createClient } from '#lib/api/client.ts';
import { FEED_MAX, feedFrom } from '#lib/feed.ts';
import { unwrap } from '#lib/load.ts';
import { feedThreads } from '#lib/threads.ts';
import type { PageLoad } from './$types';

/**
 * One Feed thread (ISS-85464): every message of it the Feed holds, oldest first, read off the same feed
 * the list threads. `at`, the created_at of its latest message, reads the feed from there, so a thread
 * the Feed's More brought in is found too (DIG-213).
 */
export const load: PageLoad = async ({ fetch, params, url }) => {
  const at = url.searchParams.get('at');
  const before = at === null ? undefined : feedFrom(at);
  const feed = unwrap(await createClient(fetch).feed({ limit: FEED_MAX, before }));
  const thread = feedThreads(feed).find((t) => t.key === params.key);
  return { messages: thread?.rows ?? [] };
};
