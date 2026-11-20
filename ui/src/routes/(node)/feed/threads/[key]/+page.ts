import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import type { PageLoad } from './$types';

/**
 * One Feed thread (ISS-85464): every message of it, oldest first, read by its key on the node
 * (DIG-225), so a thread older than the Feed's first page still shows. A key the node holds nothing
 * under is an empty thread.
 */
export const load: PageLoad = async ({ fetch, params }) => {
  const thread = await createClient(fetch).feedThread(params.key);
  return { messages: thread.status === 404 ? [] : unwrap(thread) };
};
