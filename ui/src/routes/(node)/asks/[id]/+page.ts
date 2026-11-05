import { redirect } from '@sveltejs/kit';
import { href } from '#lib/href.ts';
import type { PageLoad } from './$types';

/** Asks is the Inbox (ISS-47299): an old address opens the same ask there. */
export const load: PageLoad = ({ params }) => redirect(308, href.ask(params.id));
