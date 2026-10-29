import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import type { PageLoad } from './$types';

/** The member's own page is where the form came from and where it returns. */
export const load: PageLoad = async ({ fetch }) => ({
  self: unwrap(await createClient(fetch).members()).find((m) => m.is_self)
});
