import type {
  CommitAuthor,
  CommitAuthorForm,
  AuthorLabel,
  Organization,
  OrganizationChoice,
  Repository,
  RepositoryStatus
} from '#generated/com-bryzek-digestif-node.ts';
import { path, request, type ApiResponse } from './client.ts';

/** One page of repositories, as GET /repositories takes it. */
export interface RepositoryQuery {
  q?: string | undefined;
  status?: RepositoryStatus | undefined;
  organizationId?: string | undefined;
  limit: number;
  offset: number;
}

type Fetch = typeof fetch;

export function repositoriesUrl(query: RepositoryQuery): string {
  const params = new URLSearchParams();
  if (query.q !== undefined && query.q.trim() !== '') params.set('q', query.q.trim());
  if (query.status !== undefined) params.set('status', query.status);
  if (query.organizationId !== undefined) params.set('organization_id', query.organizationId);
  params.set('limit', String(query.limit));
  params.set('offset', String(query.offset));
  return path('repositories') + '?' + params.toString();
}

/** Repositories and commit authors (spec/digestif-node.json; DES-37265, Repositories). */
export function createRepositoriesClient(fetchFn: Fetch = fetch) {
  return {
    organizations: (): Promise<ApiResponse<Organization[]>> => request(fetchFn, 'GET', path('organizations')),
    setOrganization: (id: string, choice: OrganizationChoice): Promise<ApiResponse<Organization>> =>
      request(fetchFn, 'PUT', path('organizations', id), { choice: choice }),
    repositories: (query: RepositoryQuery): Promise<ApiResponse<Repository[]>> => request(fetchFn, 'GET', repositoriesUrl(query)),
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
