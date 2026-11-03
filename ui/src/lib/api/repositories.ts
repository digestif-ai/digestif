import type {
  CommitAuthor,
  CommitAuthorForm,
  AuthorLabel,
  Organization,
  OrganizationChoice,
  Repository,
  RepositoryStatus,
  RepositoryStatusCount
} from '#generated/com-bryzek-digestif-node.ts';
import { path, request, type ApiResponse } from './client.ts';

/** One page of repositories, as GET /repositories takes it: after the repository [cursor] names, else [offset] rows in. */
export interface RepositoryQuery {
  q?: string | undefined;
  status?: RepositoryStatus | undefined;
  organizationId?: string | undefined;
  limit: number;
  cursor?: string | undefined;
  offset?: number | undefined;
}

/** One page of organizations, as GET /organizations takes it. */
export interface OrganizationQuery {
  limit: number;
  cursor?: string | undefined;
}

export function organizationsUrl(query: OrganizationQuery): string {
  const params = new URLSearchParams();
  params.set('limit', String(query.limit));
  if (query.cursor !== undefined) params.set('cursor', query.cursor);
  return path('organizations') + '?' + params.toString();
}

type Fetch = typeof fetch;

export function repositoriesUrl(query: RepositoryQuery): string {
  const params = new URLSearchParams();
  if (query.q !== undefined && query.q.trim() !== '') params.set('q', query.q.trim());
  if (query.status !== undefined) params.set('status', query.status);
  if (query.organizationId !== undefined) params.set('organization_id', query.organizationId);
  params.set('limit', String(query.limit));
  if (query.cursor !== undefined) params.set('cursor', query.cursor);
  else if (query.offset !== undefined) params.set('offset', String(query.offset));
  return path('repositories') + '?' + params.toString();
}

/** What GET /repositories/counts takes: the list's search and organization, never its status. */
export type RepositoryCountsQuery = Pick<RepositoryQuery, 'q' | 'organizationId'>;

export function repositoryCountsUrl(query: RepositoryCountsQuery): string {
  const params = new URLSearchParams();
  if (query.q !== undefined && query.q.trim() !== '') params.set('q', query.q.trim());
  if (query.organizationId !== undefined) params.set('organization_id', query.organizationId);
  const s = params.toString();
  return path('repositories', 'counts') + (s === '' ? '' : '?' + s);
}

/** Repositories and commit authors (spec/digestif-node.json; DES-37265, Repositories). */
export function createRepositoriesClient(fetchFn: Fetch = fetch) {
  return {
    organizations: (query: OrganizationQuery): Promise<ApiResponse<Organization[]>> => request(fetchFn, 'GET', organizationsUrl(query)),
    setOrganization: (id: string, choice: OrganizationChoice): Promise<ApiResponse<Organization>> =>
      request(fetchFn, 'PUT', path('organizations', id), { choice: choice }),
    repositories: (query: RepositoryQuery): Promise<ApiResponse<Repository[]>> => request(fetchFn, 'GET', repositoriesUrl(query)),
    repositoryCounts: (query: RepositoryCountsQuery): Promise<ApiResponse<RepositoryStatusCount[]>> =>
      request(fetchFn, 'GET', repositoryCountsUrl(query)),
    setRepository: (id: string, status: RepositoryStatus): Promise<ApiResponse<Repository>> =>
      request(fetchFn, 'PUT', path('repositories', id), { status: status }),
    commitAuthors: (): Promise<ApiResponse<CommitAuthor[]>> => request(fetchFn, 'GET', path('commit_authors')),
    addCommitAuthor: (form: CommitAuthorForm): Promise<ApiResponse<CommitAuthor>> => request(fetchFn, 'POST', path('commit_authors'), form),
    labelCommitAuthor: (id: string, label: AuthorLabel): Promise<ApiResponse<CommitAuthor>> =>
      request(fetchFn, 'PUT', path('commit_authors', id), { label: label }),
    removeCommitAuthor: (id: string): Promise<ApiResponse<undefined>> => request(fetchFn, 'DELETE', path('commit_authors', id))
  };
}

export type RepositoriesClient = ReturnType<typeof createRepositoriesClient>;
