import { createClient } from '#lib/api/client.ts';
import { everyMember, unwrap } from '#lib/load.ts';
import type { PageLoad } from './$types';

/** The prompt a suggestion starts from, and the members who may judge it: every member of the circle (DIG-225). */
export const load: PageLoad = async ({ fetch }) => {
  const client = createClient(fetch);
  const [notePrompt, members] = await Promise.all([client.notePrompt(), everyMember(client)]);
  return { notePrompt: unwrap(notePrompt), members };
};
