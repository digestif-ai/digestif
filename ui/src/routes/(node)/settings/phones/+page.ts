import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import { phonesOf } from '#lib/phones.ts';
import type { PageLoad } from './$types';

export const load: PageLoad = async ({ fetch }) => {
  const client = createClient(fetch);
  const self = unwrap(await client.members()).find((m) => m.is_self);
  const member = self === undefined ? undefined : unwrap(await client.member(self.identity));
  return { phones: phonesOf(member?.devices ?? []) };
};
