import { redirect } from '@sveltejs/kit';
import { href } from '#lib/href.ts';
import type { PageLoad } from './$types';

/** While setup is open the app is the first note's page; afterwards the feed. */
export const load: PageLoad = async ({ parent }) => {
  const { status } = await parent();
  redirect(307, status.first_run || status.first_note !== undefined ? href.firstNote() : href.feed());
};
