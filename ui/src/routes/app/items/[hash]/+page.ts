import { error } from '@sveltejs/kit';
import type { PageLoad } from './$types';

export const load: PageLoad = async ({ parent, params }) => {
  const { phone } = await parent();
  if (phone.stage !== 'paired') error(404, 'Pair this phone first.');
  const item = phone.items.find((i) => i.hash === params.hash);
  if (item === undefined) error(404, 'No such item.');
  return { item };
};
