import { redirect } from '@sveltejs/kit';
import { href } from '#lib/href.ts';
import type { PageLoad } from './$types';

/** A note's Log is on its message (ISS-47299). */
export const load: PageLoad = ({ params }) => redirect(308, href.note(params.id));
