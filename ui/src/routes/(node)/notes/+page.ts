import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import type { PageLoad } from './$types';

export const load: PageLoad = async ({ fetch }) => {
  const client = createClient(fetch);
  const [notes, problems] = await Promise.all([client.notes(), client.problems(true)]);
  return { notes: unwrap(notes), problems: unwrap(problems) };
};
