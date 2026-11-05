import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import type { PageLoad } from './$types';

/** The feed, the open problems at its top, and what Notes used to say beside its list: the auto
 * approval suggestion and that there has been no activity yet (ISS-47299). */
export const load: PageLoad = async ({ fetch }) => {
  const client = createClient(fetch);
  const [feed, problems, notes] = await Promise.all([client.feed(), client.problems(true), client.notes({ limit: 1 })]);
  return { feed: unwrap(feed), problems: unwrap(problems), notes: unwrap(notes) };
};
