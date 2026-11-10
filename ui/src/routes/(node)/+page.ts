import { redirect } from '@sveltejs/kit';
import { href } from '#lib/href.ts';
import type { PageLoad } from './$types';

/** From the setup chat starting it until it goes out the app is the first note's page; before it, setup continues in the terminal; afterwards the inbox. */
export const load: PageLoad = async ({ parent }) => {
  const { status } = await parent();
  if (status.first_note !== undefined) redirect(307, href.note(status.first_note.id));
  if (!status.first_run) redirect(307, href.inbox());
  return {};
};
