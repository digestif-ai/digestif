import { error } from '@sveltejs/kit';
import { createClient } from '#lib/api/client.ts';
import { unwrap } from '#lib/load.ts';
import { phonesOf } from '#lib/phones.ts';
import type { PageLoad } from './$types';

export const load: PageLoad = async ({ fetch, params }) => {
  const client = createClient(fetch);
  const self = unwrap(await client.members()).find((m) => m.is_self);
  const member = self === undefined ? undefined : unwrap(await client.member(self.identity));
  const phone = phonesOf(member?.devices ?? []).find((d) => d.key === params.key);
  if (phone === undefined) error(404, 'Not found.');
  return { phone };
};
