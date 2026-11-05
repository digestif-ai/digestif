import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import type { PageLoad } from './$types';

/** A message; one the agent wrote as a note carries the note too, its versions and its Log, since a
 * note is approved on its message (ISS-47299). `?version=` keeps the version the member is reading. */
export const load: PageLoad = async ({ fetch, params, url }) => {
  const client = createClient(fetch);
  const message = unwrap(await client.message(params.hash));
  if (message.note_id === undefined) return { message, note: undefined };
  const id = message.note_id;
  const version = url.searchParams.get('version') ?? undefined;
  const [note, versions, log] = await Promise.all([client.note(id, version), client.noteVersions(id), client.noteLog(id)]);
  const n = unwrap(note);
  const newer = n.newer_version_id === undefined ? undefined : unwrap(await client.note(id, n.newer_version_id)).version;
  return { message, note: { note: n, newer, versions: unwrap(versions), log: unwrap(log) } };
};
