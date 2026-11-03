import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import { pageOf, pageQuery } from '#lib/paging.ts';
import type { PageLoad } from './$types';

/** The first page of the deny list, beside the rules' built-in detectors; More reads the rest (ISS-41988). */
export const load: PageLoad = async ({ fetch }) => {
  const client = createClient(fetch);
  const [deny, rules] = await Promise.all([client.denyList(pageQuery()), client.rules()]);
  return { deny: pageOf(unwrap(deny)), detectors: unwrap(rules).detectors };
};
