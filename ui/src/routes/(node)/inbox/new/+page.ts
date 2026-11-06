import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import type { PageLoad } from './$types';

/** Whom an item can be addressed to: the circle is small and invite-only, so one page holds it. */
export const load: PageLoad = async ({ fetch }) => ({ members: unwrap(await createClient(fetch).members({ limit: 200 })) });
