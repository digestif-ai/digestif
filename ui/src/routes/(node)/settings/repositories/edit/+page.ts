import { createRepositoriesClient } from '#lib/api/repositories.ts';
import { unwrap } from '#lib/load.ts';
import { ORGANIZATION_PAGE, REPOSITORY_PAGE } from '#lib/repositories.ts';
import type { PageLoad } from './$types';

// The first page of organizations, and each one's first page of repositories beside it, each read
// one more row than a page so the pager knows whether there is a next (ISS-41944).
export const load: PageLoad = async ({ fetch }) => {
  const client = createRepositoriesClient(fetch);
  const [organizations, authors] = await Promise.all([client.organizations({ limit: ORGANIZATION_PAGE + 1 }), client.commitAuthors()]);
  const page = unwrap(organizations);
  const orgs = page.slice(0, ORGANIZATION_PAGE);
  const firstPages = await Promise.all(
    orgs.map(async (o) => [o.id, unwrap(await client.repositories({ organizationId: o.id, limit: REPOSITORY_PAGE + 1 }))] as const)
  );
  return {
    organizations: orgs,
    moreOrganizations: page.length > ORGANIZATION_PAGE,
    authors: unwrap(authors),
    firstPages: Object.fromEntries(firstPages)
  };
};
