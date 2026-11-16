import { createClient } from '#lib/api/client.ts';
import { INBOX_PAGE, readInbox } from '#lib/inbox.ts';
import { inboxFrom, inboxView } from '#lib/items.ts';
import { unwrap } from '#lib/load.ts';
import { pageOf, pageQuery } from '#lib/paging.ts';
import type { PageLoad } from './$types';

/**
 * The first page of the member's items in the view and From the filters name, the Inbox itself unless
 * it names another view (DIG-476, ISS-88476, DIG-128); More reads the rest through the same filters
 * (ISS-41988), 25 rows at a time (DIG-474). The node filters both, so the circle, read beside them, is
 * only for the From column, which names the member's own items (the circle is small, so one page holds it).
 */
export const load: PageLoad = async ({ fetch, url }) => {
  const state = inboxView(url.searchParams);
  const from = inboxFrom(url.searchParams);
  const client = createClient(fetch);
  const [members, items] = await Promise.all([
    client.members({ limit: 200 }),
    readInbox(client, { state, from }, pageQuery(undefined, INBOX_PAGE))
  ]);
  const self = unwrap(members).find((m) => m.is_self)?.identity;
  return { state, from, self, items: pageOf(unwrap(items), INBOX_PAGE) };
};
