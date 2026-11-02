import type { PageLoad } from './$types';

export const load: PageLoad = async ({ parent }) => {
  const { status } = await parent();
  return { firstNote: status.first_note };
};
