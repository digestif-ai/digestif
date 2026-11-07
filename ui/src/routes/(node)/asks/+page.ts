import { redirect } from '@sveltejs/kit';
import { href } from '#lib/href.ts';
import type { PageLoad } from './$types';

/** Asks is the Inbox (ISS-47299): an old address opens it. */
export const load: PageLoad = () => redirect(308, href.inbox());
