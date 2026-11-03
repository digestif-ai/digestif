import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import type { PageLoad } from './$types';

/** No agent saved yet is a 404: the form starts empty. */
export const load: PageLoad = async ({ fetch }) => {
  const agent = await createClient(fetch).agent();
  return { agent: agent.status === 404 ? undefined : unwrap(agent) };
};
