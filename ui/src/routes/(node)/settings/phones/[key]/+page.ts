import { error } from '@sveltejs/kit';
import { createClient } from '#lib/api/client.ts';
import { selfOf } from '#lib/load.ts';
import { phonesOf } from '#lib/phones.ts';
import type { PageLoad } from './$types';

export const load: PageLoad = async ({ fetch, params }) => {
  const member = await selfOf(createClient(fetch));
  const phone = phonesOf(member?.devices ?? []).find((d) => d.key === params.key);
  if (phone === undefined) error(404, 'Not found.');
  return { phone };
};
