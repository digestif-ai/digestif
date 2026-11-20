import { createClient } from '#lib/api/client.ts';
import { INBOX_PAGE, readInbox } from '#lib/inbox.ts';
import { inboxFrom, inboxView } from '#lib/items.ts';
import { selfOf, unwrap } from '#lib/load.ts';
import { pageOf, pageQuery } from '#lib/paging.ts';
import type { PageLoad } from './$types';

/**
 * The first page of the member's items in the view and From the filters name, the Inbox itself unless
 * it names another view (DIG-476, ISS-88476, DIG-128); More reads the rest through the same filters
 * (ISS-41988), 25 rows at a time (DIG-474). The node filters both, so the member, read beside them, is
 * only for the From column, which names the member's own items (DIG-225).
 */
export const load: PageLoad = async ({ fetch, url }) => {
  const state = inboxView(url.searchParams);
  const from = inboxFrom(url.searchParams);
  const client = createClient(fetch);
  const [member, items] = await Promise.all([
    selfOf(client),
    readInbox(client, { state, from }, pageQuery(undefined, INBOX_PAGE))
  ]);
  const self = member?.identity;
  return { state, from, self, items: pageOf(unwrap(items), INBOX_PAGE) };
};
