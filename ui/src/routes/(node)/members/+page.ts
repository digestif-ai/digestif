import { CircleApprovalState } from '#generated/ai-digestif-digestif-node.ts';
import { createClient } from '#lib/api/client.ts';
import { loaded, unwrap } from '#lib/load.ts';
import { pageOf, pageQuery } from '#lib/paging.ts';
import type { PageLoad } from './$types';

/**
 * The first page of members, beside the invitees; More reads the rest (ISS-41988). An admin also
 * reads the waiting approvals and the signer set, which says who is an admin and whether a revoked key
 * halts invites (DES-85466); a member who is not an admin reads no approvals.
 */
export const load: PageLoad = async ({ fetch }) => {
  const client = createClient(fetch);
  const [members, invitees, approvals, signers] = await Promise.all([
    client.members(pageQuery()),
    client.invitees(),
    client.approvals([CircleApprovalState.Waiting]),
    client.signers()
  ]);
  return { members: pageOf(unwrap(members)), invitees: unwrap(invitees), approvals: loaded(approvals), signers: loaded(signers) };
};
