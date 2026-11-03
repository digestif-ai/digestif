import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import { pageOf, pageQuery } from '#lib/paging.ts';
import type { PageLoad } from './$types';

/** The first page of members, beside the invitees; More reads the rest (ISS-41988). */
export const load: PageLoad = async ({ fetch }) => {
  const client = createClient(fetch);
  const [members, invitees] = await Promise.all([client.members(pageQuery()), client.invitees()]);
  return { members: pageOf(unwrap(members)), invitees: unwrap(invitees) };
};
