import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import { pageOf, pageQuery } from '#lib/paging.ts';
import type { PageLoad } from './$types';

/** The first page of asks; More reads the rest (ISS-41988). */
export const load: PageLoad = async ({ fetch }) => ({ asks: pageOf(unwrap(await createClient(fetch).asks(undefined, pageQuery()))) });
