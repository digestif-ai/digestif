import { createClient } from '#lib/api/client.ts';
import { readFeed } from '#lib/feed.ts';
import { unwrap } from '#lib/load.ts';
import { pageOf, pageQuery } from '#lib/paging.ts';
import type { PageLoad } from './$types';

/** The feed's first page, More reading the older ones (DIG-213), the open problems at its top, and what
 * Notes used to say beside its list: the auto approval suggestion and that there has been no activity yet (ISS-47299). */
export const load: PageLoad = async ({ fetch, parent }) => {
  const client = createClient(fetch);
  const [feed, problems, notes, { status }] = await Promise.all([
    readFeed(client, pageQuery()),
    client.problems(true),
    client.notes({ limit: 1 }),
    parent()
  ]);
  return { feed: pageOf(unwrap(feed)), problems: unwrap(problems), notes: unwrap(notes), status: await status };
};
