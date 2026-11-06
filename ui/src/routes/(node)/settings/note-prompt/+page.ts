import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import { pageOf, pageQuery } from '#lib/paging.ts';
import type { PageLoad } from './$types';

/** The circle's live note prompt, and the first page of the suggestions to change it; More reads the rest. */
export const load: PageLoad = async ({ fetch }) => {
  const client = createClient(fetch);
  const [notePrompt, suggestions] = await Promise.all([client.notePrompt(), client.promptSuggestions(pageQuery())]);
  return { notePrompt: unwrap(notePrompt), suggestions: pageOf(unwrap(suggestions)) };
};
