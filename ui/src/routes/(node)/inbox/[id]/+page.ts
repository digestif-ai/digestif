import { ItemSubject } from '#generated/ai-digestif-digestif-node.ts';
import { createClient } from '#lib/api/client.ts';
import { loaded, selfOf, unwrap } from '#lib/load.ts';
import type { PageLoad } from './$types';

/**
 * The item, and which member is this node's (DIG-225). A member review's item (DES-376) also reads
 * the member it is about and the signer set, whose members are the admins it asks.
 */
export const load: PageLoad = async ({ fetch, params, parent }) => {
  const client = createClient(fetch);
  const [item, self, { status }] = await Promise.all([client.item(params.id), selfOf(client), parent()]);
  const it = unwrap(item);
  const review =
    it.subject === ItemSubject.Review && it.about !== undefined
      ? await Promise.all([client.member(it.about), client.signers()]).then(([member, signers]) => ({
          member: loaded(member),
          signers: loaded(signers)
        }))
      : undefined;
  return { item: it, self: self?.identity, status: await status, review };
};
