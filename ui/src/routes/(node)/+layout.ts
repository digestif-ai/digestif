import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import type { LayoutLoad } from './$types';

// The node's own screens: every page renders against the local API (spec/digestif-node.json).
// The status is streamed, never awaited here: it carries the header's counts and the stage, and a
// layout that awaited it would hold every page's rows until the slowest call answered (rows first,
// counts after, ISS-83181). A page that reads the status itself awaits it in its own load; the
// layout sends a node that is Paused to the Paused page, and the Paused page away once it is not.
export const load: LayoutLoad = ({ fetch, depends }) => {
  depends('digestif:status');
  return { status: createClient(fetch).status().then(unwrap) };
};
