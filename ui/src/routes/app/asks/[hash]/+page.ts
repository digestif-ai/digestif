import { error } from '@sveltejs/kit';
import type { PageLoad } from './$types';

export const load: PageLoad = async ({ parent, params }) => {
  const { phone } = await parent();
  if (phone.stage !== 'paired') error(404, 'Pair this phone first.');
  const ask = phone.asks.find((a) => a.hash === params.hash);
  if (ask === undefined) error(404, 'No such ask.');
  return { ask };
};
