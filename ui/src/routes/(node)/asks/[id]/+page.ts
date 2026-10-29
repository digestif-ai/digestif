import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import type { PageLoad } from './$types';

export const load: PageLoad = async ({ fetch, params }) => ({ ask: unwrap(await createClient(fetch).ask(params.id)) });
