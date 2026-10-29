import { read } from '#lib/phone/phone.ts';
import type { LayoutLoad } from './$types';

// The phone web app (docs/protocol.md, The phone): the mailing relay serves this build under /app/,
// and the phone talks to that relay with a key of its own.
export const load: LayoutLoad = async ({ depends }) => {
  depends('phone:state');
  return { phone: await read() };
};
