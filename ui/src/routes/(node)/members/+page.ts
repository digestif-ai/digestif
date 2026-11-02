import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import type { PageLoad } from './$types';

export const load: PageLoad = async ({ fetch }) => {
  const client = createClient(fetch);
  const [members, invitees] = await Promise.all([client.members(), client.invitees()]);
  return { members: unwrap(members), invitees: unwrap(invitees) };
};
