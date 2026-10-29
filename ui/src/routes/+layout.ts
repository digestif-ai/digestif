import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import type { LayoutLoad } from './$types';

// A static build the node embeds: every page renders in the browser against the local API.
export const ssr = false;
export const prerender = false;

export const load: LayoutLoad = async ({ fetch, depends }) => {
  depends('digestif:status');
  return { status: unwrap(await createClient(fetch).status()) };
};
