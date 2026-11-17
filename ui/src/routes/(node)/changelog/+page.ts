import { readChangelog } from '#lib/changelog.ts';
import type { PageLoad } from './$types';

/** What each release changed, from the changelog.json the node's own build carries (DIG-128), beside the running version. */
export const load: PageLoad = async ({ fetch, parent }) => {
  const { status } = await parent();
  const [changelog, s] = await Promise.all([readChangelog(fetch), status.catch(() => undefined)]);
  return { changelog, version: s?.version };
};
