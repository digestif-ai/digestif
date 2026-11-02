import { redirect } from '@sveltejs/kit';
import { Stage } from '#generated/com-bryzek-digestif-node.ts';
import { createClient } from '#lib/api/client.ts';
import { href } from '#lib/href.ts';
import { unwrap } from '#lib/load.ts';
import type { LayoutLoad } from './$types';

// The node's own screens: every page renders against the local API (spec/digestif-node.json).
// While Paused the whole app is the Paused page, and the Paused page is nothing otherwise.
export const load: LayoutLoad = async ({ fetch, depends, url }) => {
  depends('digestif:status');
  const status = unwrap(await createClient(fetch).status());
  const onPaused = url.pathname === href.paused();
  if (status.stage === Stage.Paused && !onPaused) redirect(307, href.paused());
  if (status.stage !== Stage.Paused && onPaused) redirect(307, href.feed());
  return { status };
};
