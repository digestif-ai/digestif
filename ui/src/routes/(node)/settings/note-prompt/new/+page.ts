import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import type { PageLoad } from './$types';

/** The prompt a suggestion starts from, and the members who may judge it. */
export const load: PageLoad = async ({ fetch }) => {
  const client = createClient(fetch);
  const [notePrompt, members] = await Promise.all([client.notePrompt(), client.members({ limit: 200 })]);
  return { notePrompt: unwrap(notePrompt), members: unwrap(members) };
};
