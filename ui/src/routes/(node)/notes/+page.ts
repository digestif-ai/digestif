import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import { pageQuery } from '#lib/paging.ts';
import type { PageLoad } from './$types';

/** The first page of notes, one more than shown so More knows there are others (ISS-41988). */
export const load: PageLoad = async ({ fetch }) => {
  const client = createClient(fetch);
  const [notes, problems] = await Promise.all([client.notes(pageQuery()), client.problems(true)]);
  return { notes: unwrap(notes), problems: unwrap(problems) };
};
