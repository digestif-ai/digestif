import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import type { LayoutLoad } from './$types';

// The node's own screens: every page renders against the local API (spec/digestif-node.json).
export const load: LayoutLoad = async ({ fetch, depends }) => {
  depends('digestif:status');
  return { status: unwrap(await createClient(fetch).status()) };
};
