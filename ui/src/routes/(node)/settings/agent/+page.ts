import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import type { PageLoad } from './$types';

/** No agent saved yet is a 404, and so is no check since the node started: each starts empty. */
export const load: PageLoad = async ({ fetch }) => {
  const client = createClient(fetch);
  const [agent, check] = await Promise.all([client.agent(), client.agentCheck()]);
  return {
    agent: agent.status === 404 ? undefined : unwrap(agent),
    check: check.status === 404 ? undefined : unwrap(check)
  };
};
