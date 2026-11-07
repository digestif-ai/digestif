import { error } from '@sveltejs/kit';
import type { PageLoad } from './$types';

export const load: PageLoad = async ({ parent, params }) => {
  const { phone } = await parent();
  if (phone.stage !== 'paired') error(404, 'Pair this phone first.');
  const choice = phone.choices.find((c) => c.hash === params.hash);
  if (choice === undefined) error(404, 'No such choice.');
  return { choice };
};
