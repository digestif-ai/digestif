import { redirect } from '@sveltejs/kit';
import { href } from '#lib/href.ts';
import type { PageLoad } from './$types';

/** Asks became the Inbox's items (DES-51007), which an ask's id does not name: an old address opens the Inbox. */
export const load: PageLoad = () => redirect(308, href.inbox());
