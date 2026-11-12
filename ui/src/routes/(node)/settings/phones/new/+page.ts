import type { PageLoad } from './$types';

/** The status names the phone app's address; the layout streams it, so the page awaits it. */
export const load: PageLoad = async ({ parent }) => ({ status: await (await parent()).status });
