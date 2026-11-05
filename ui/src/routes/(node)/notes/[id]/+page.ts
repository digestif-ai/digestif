import { redirect } from '@sveltejs/kit';
import { href } from '#lib/href.ts';
import type { PageLoad } from './$types';

/** A note is read and approved on its message (ISS-47299): /notes/<id> opens it there, keeping the version. */
export const load: PageLoad = ({ params, url }) => redirect(308, href.note(params.id, url.searchParams.get('version') ?? undefined));
