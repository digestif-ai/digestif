import { createClient } from '#lib/api/client.ts';
import { everyMember } from '#lib/load.ts';
import type { PageLoad } from './$types';

/** Whom an item can be addressed to: every member of the circle (DIG-225). */
export const load: PageLoad = async ({ fetch }) => ({ members: await everyMember(createClient(fetch)) });
