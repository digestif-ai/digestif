import { createClient } from '#lib/api/client.ts';
import { selfOf } from '#lib/load.ts';
import { phonesOf } from '#lib/phones.ts';
import type { PageLoad } from './$types';

export const load: PageLoad = async ({ fetch }) => {
  const member = await selfOf(createClient(fetch));
  return { phones: phonesOf(member?.devices ?? []) };
};
