import { createRepositoriesClient } from '#lib/api/repositories.ts';
import { unwrap } from '#lib/load.ts';
import { RepositoryStatus } from '#generated/com-bryzek-digestif-node.ts';
import { ORGANIZATION_PAGE, REPOSITORY_PAGE } from '#lib/repositories.ts';
import type { PageLoad } from './$types';

// The first page of organizations, and each one's first page of repositories beside it, each read
// one more row than a page so the pager knows whether there is a next (ISS-41944).
// `?status=` opens the page under that chip: the New repositories ask opens it under Undecided.
export const load: PageLoad = async ({ fetch, url }) => {
  const client = createRepositoriesClient(fetch);
  const asked = url.searchParams.get('status');
  const status = Object.values(RepositoryStatus).find((s) => s === asked);
  const [organizations, authors] = await Promise.all([client.organizations({ limit: ORGANIZATION_PAGE + 1 }), client.commitAuthors()]);
  const page = unwrap(organizations);
  const orgs = page.slice(0, ORGANIZATION_PAGE);
  const firstPages = await Promise.all(
    orgs.map(async (o) => [o.id, unwrap(await client.repositories({ organizationId: o.id, status, limit: REPOSITORY_PAGE + 1 }))] as const)
  );
  return {
    organizations: orgs,
    moreOrganizations: page.length > ORGANIZATION_PAGE,
    status,
    authors: unwrap(authors),
    firstPages: Object.fromEntries(firstPages)
  };
};
