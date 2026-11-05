import { redirect } from '@sveltejs/kit';
import { href } from '#lib/href.ts';
import type { PageLoad } from './$types';

/** Notes is gone: a note is approved on its message in the Feed (ISS-47299). */
export const load: PageLoad = () => redirect(308, href.feed());
