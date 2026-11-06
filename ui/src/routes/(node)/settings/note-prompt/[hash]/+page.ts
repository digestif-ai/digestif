import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import type { PageLoad } from './$types';

export const load: PageLoad = async ({ fetch, params }) => ({
  suggestion: unwrap(await createClient(fetch).promptSuggestion(params.hash))
});
