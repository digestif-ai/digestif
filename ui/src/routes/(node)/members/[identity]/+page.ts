import { createClient } from '#lib/api/client.ts';
import { loaded, unwrap } from '#lib/load.ts';
import type { PageLoad } from './$types';

/**
 * The member, beside the circle (which says which member is this node's, so whether the reader is an
 * admin) and the signer set, which decides Promote to Admin and Remove as Admin (DES-85466).
 */
export const load: PageLoad = async ({ fetch, params }) => {
  const client = createClient(fetch);
  const [member, members, signers] = await Promise.all([client.member(params.identity), client.members({ limit: 200 }), client.signers()]);
  const self = 'data' in members ? members.data.find((m) => m.is_self) : undefined;
  return { member: unwrap(member), self, signers: loaded(signers) };
};
