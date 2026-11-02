import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import type { PageLoad } from './$types';

/** The note page keeps the version the member is reading (?version=), and says when an edit made a newer one. */
export const load: PageLoad = async ({ fetch, params, url }) => {
  const client = createClient(fetch);
  const version = url.searchParams.get('version') ?? undefined;
  const note = unwrap(await client.note(params.id, version));
  const newer = note.newer_version_id === undefined ? undefined : unwrap(await client.note(params.id, note.newer_version_id)).version;
  return { note, newer };
};
