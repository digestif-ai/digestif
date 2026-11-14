import type { PageLoad } from './$types';

/**
 * The admin's name signs the email (node/invite/invite_email.ml). An admin's agent fills the page
 * from the address digestif invite prints: to, role and message, the admin's own lines (DES-85466, The relay's new rule).
 */
export const load: PageLoad = async ({ parent, url }) => {
  const { status } = await parent();
  const q = url.searchParams;
  const s = await status;
  return {
    sender: s.member_name ?? '',
    circle: s.circle_label ?? '',
    to: q.get('to') ?? '',
    role: q.get('role') === 'admin' ? 'admin' : 'member',
    message: q.get('message') ?? ''
  };
};
