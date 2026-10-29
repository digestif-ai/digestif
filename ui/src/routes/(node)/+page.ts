import { redirect } from '@sveltejs/kit';
import { href } from '#lib/href.ts';
import type { PageLoad } from './$types';

/** First run is the source picker, with nothing selected; afterwards the feed. */
export const load: PageLoad = async ({ parent }) => {
  const { status } = await parent();
  redirect(307, status.first_run ? href.sourcesEdit() : href.feed());
};
