import { createRepositoriesClient } from '#lib/api/repositories.ts';
import { unwrap } from '#lib/load.ts';
import { REPOSITORY_PAGE } from '#lib/repositories.ts';
import type { PageLoad } from './$types';

// Each organization's first page is read beside the organizations, one more row than a page so the
// pager knows whether there is a next.
export const load: PageLoad = async ({ fetch }) => {
  const client = createRepositoriesClient(fetch);
  const [organizations, authors] = await Promise.all([client.organizations(), client.commitAuthors()]);
  const orgs = unwrap(organizations);
  const firstPages = await Promise.all(
    orgs.map(
      async (o) => [o.id, unwrap(await client.repositories({ organizationId: o.id, limit: REPOSITORY_PAGE + 1, offset: 0 }))] as const
    )
  );
  return { organizations: orgs, authors: unwrap(authors), firstPages: Object.fromEntries(firstPages) };
};
