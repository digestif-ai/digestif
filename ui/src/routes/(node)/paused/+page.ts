import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import type { PageLoad } from './$types';

export const load: PageLoad = async ({ fetch }) => ({ paused: unwrap(await createClient(fetch).paused()) });
