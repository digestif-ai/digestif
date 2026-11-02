import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import type { PageLoad } from './$types';

export const load: PageLoad = async ({ fetch, params }) => {
  const client = createClient(fetch);
  const [note, log] = await Promise.all([client.note(params.id), client.noteLog(params.id)]);
  return { note: unwrap(note), log: unwrap(log) };
};
