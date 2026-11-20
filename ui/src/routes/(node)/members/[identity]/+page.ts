import { createClient } from '#lib/api/client.ts';
import { loaded, selfOf, unwrap } from '#lib/load.ts';
import type { PageLoad } from './$types';

/**
 * The member, beside the member this node is (whether the reader is an admin, DIG-225) and the signer set, which decides Promote to Admin and Remove as Admin (DES-85466).
 */
export const load: PageLoad = async ({ fetch, params }) => {
  const client = createClient(fetch);
  const [member, self, signers] = await Promise.all([client.member(params.identity), selfOf(client), client.signers()]);
  return { member: unwrap(member), self, signers: loaded(signers) };
};
