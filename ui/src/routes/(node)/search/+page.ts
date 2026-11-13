import { createClient } from '#lib/api/client.ts';
import { runSearch } from '#lib/search.ts';
import type { PageLoad } from './$types';

/** The search for ?q=, streamed: the page and its box show at once and the rows follow. */
export const load: PageLoad = ({ fetch, url }) => {
  const q = url.searchParams.get('q') ?? '';
  return { q, result: runSearch(q, createClient(fetch)) };
};
