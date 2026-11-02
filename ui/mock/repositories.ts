// Repositories and commit authors for the mock node, seeded as the demo node seeds them
// (node/web/demo.ml, repositories) so the Playwright suite reads the same page from both, and
// following the node's rules (node/web/store.ml, Repositories).
import {
  AuthorLabel,
  OrganizationChoice,
  RepositoryStatus,
  type CommitAuthor,
  type NodeError,
  type Organization,
  type Repository
} from '#generated/com-bryzek-digestif-node.ts';

interface MockResponse {
  status: number;
  body?: unknown;
}

type Route = [string, string, (p: string[], body: unknown, q: URLSearchParams) => MockResponse];

const err = (status: number, code: string, message: string, field?: string): MockResponse => ({
  status,
  body: [{ code, message, ...(field === undefined ? {} : { field: field }) } satisfies NodeError]
});
const notFound = (): MockResponse => err(404, 'not_found', 'Not found.');
const ok = (body: unknown, status = 200): MockResponse => ({ status, body });

function field(body: unknown, name: string): string | undefined {
  if (body === null || typeof body !== 'object') return undefined;
  const v = (body as Record<string, unknown>)[name];
  return typeof v === 'string' ? v : undefined;
}

function oneOf<T extends string>(values: T[], v: string | undefined): T | undefined {
  return values.find((x) => x === v);
}

interface StoredOrganization {
  id: string;
  name: string;
  choice: OrganizationChoice;
}

export class MockRepositories {
  organizations: StoredOrganization[];
  repositories: Repository[];
  authors: CommitAuthor[];
  nextId = 0;

  constructor(now: Date = new Date()) {
    const ago = (hours: number): string => new Date(now.getTime() - hours * 3600_000).toISOString();
    const repo = (organization_id: string, name: string, status: RepositoryStatus, hours: number): Repository => ({
      id: organization_id.startsWith('local:') ? organization_id : organization_id + '/' + name,
      organization_id,
      name,
      status,
      found_at: ago(hours)
    });
    this.organizations = [
      { id: 'github.com/acme-labs', name: 'acme-labs', choice: OrganizationChoice.Chosen },
      { id: 'github.com/ada-park', name: 'ada-park', choice: OrganizationChoice.AllAutomatic },
      { id: 'local:~/demo/dotfiles', name: 'dotfiles', choice: OrganizationChoice.AllAutomatic },
      { id: 'github.com/example-co', name: 'example-co', choice: OrganizationChoice.All }
    ];
    this.repositories = [
      repo('github.com/acme-labs', 'prototype', RepositoryStatus.Undecided, 30),
      repo('github.com/ada-park', 'side-project', RepositoryStatus.Approved, 400),
      repo('local:~/demo/dotfiles', 'dotfiles', RepositoryStatus.Approved, 400),
      repo('github.com/example-co', 'importer', RepositoryStatus.Approved, 400),
      repo('github.com/example-co', 'loader', RepositoryStatus.Approved, 400),
      repo('github.com/example-co', 'web', RepositoryStatus.Declined, 400)
    ];
    this.authors = [
      { id: 'author-1', email: 'ada@example.com', name: 'Ada Park', label: AuthorLabel.Yours, member_set: false },
      { id: 'author-2', email: 'hermes-bot@example.com', name: 'Hermes', label: AuthorLabel.YourFleet, member_set: false }
    ];
  }

  private organization(o: StoredOrganization): Organization {
    return { ...o, repositories: this.repositories.filter((r) => r.organization_id === o.id).length };
  }

  private orgName(id: string): string {
    return this.organizations.find((o) => o.id === id)?.name ?? '';
  }

  private sortedAuthors(): CommitAuthor[] {
    const rank = (a: CommitAuthor): number => (a.label === AuthorLabel.Yours ? 0 : 1);
    return [...this.authors].sort((a, b) => rank(a) - rank(b) || a.email.localeCompare(b.email));
  }

  private list(q: URLSearchParams): MockResponse {
    const limit = Number(q.get('limit') ?? '50');
    const offset = Number(q.get('offset') ?? '0');
    if (!Number.isInteger(limit) || limit < 1 || limit > 200) return err(422, 'limit', 'Not a valid limit.', 'limit');
    if (!Number.isInteger(offset) || offset < 0) return err(422, 'offset', 'Not a valid offset.', 'offset');
    const status = q.get('status');
    if (status !== null && status !== '' && oneOf(Object.values(RepositoryStatus), status) === undefined) {
      return err(422, 'status', 'Unknown status.', 'status');
    }
    const term = (q.get('q') ?? '').trim().toLowerCase();
    const org = q.get('organization_id');
    const key = (r: Repository): string =>
      this.orgName(r.organization_id).toLowerCase() + '\u0000' + r.organization_id + '\u0000' + r.name.toLowerCase();
    const rows = this.repositories
      .filter((r) => term === '' || r.name.toLowerCase().includes(term) || this.orgName(r.organization_id).toLowerCase().includes(term))
      .filter((r) => status === null || status === '' || r.status === status)
      .filter((r) => org === null || org === '' || r.organization_id === org)
      .sort((a, b) => key(a).localeCompare(key(b)));
    return ok(rows.slice(offset, offset + limit));
  }

  routes(): Route[] {
    return [
      ['GET', 'organizations', () => ok(this.organizations.map((o) => this.organization(o)))],
      [
        'PUT',
        'organizations/:',
        ([id], b) => {
          const o = this.organizations.find((x) => x.id === id);
          if (o === undefined) return notFound();
          const choice = oneOf(Object.values(OrganizationChoice), field(b, 'choice'));
          if (choice === undefined) return err(422, 'choice', 'Choose one of: all_automatic, all, chosen.', 'choice');
          o.choice = choice;
          if (choice !== OrganizationChoice.Chosen) {
            for (const r of this.repositories) {
              if (r.organization_id === id && r.status === RepositoryStatus.Undecided) r.status = RepositoryStatus.Approved;
            }
          }
          return ok(this.organization(o));
        }
      ],
      ['GET', 'repositories', (_p, _b, q) => this.list(q)],
      [
        'PUT',
        'repositories/:',
        ([id], b) => {
          const r = this.repositories.find((x) => x.id === id);
          if (r === undefined) return notFound();
          const status = oneOf(Object.values(RepositoryStatus), field(b, 'status'));
          if (status === undefined) return err(422, 'status', 'Choose one of: approved, declined, undecided.', 'status');
          r.status = status;
          return ok(r);
        }
      ],
      ['GET', 'commit_authors', () => ok(this.sortedAuthors())],
      [
        'POST',
        'commit_authors',
        (_p, b) => {
          const email = (field(b, 'email') ?? '').trim().toLowerCase();
          if (email === '') return err(422, 'empty', 'Enter an email.', 'email');
          const label = oneOf(Object.values(AuthorLabel), field(b, 'label'));
          if (label === undefined) return err(422, 'label', 'Choose one of: yours, your_fleet.', 'label');
          if (this.authors.some((a) => a.email === email)) return err(422, 'duplicate', 'That email is already an author.', 'email');
          const name = (field(b, 'name') ?? '').trim();
          this.nextId += 1;
          const author: CommitAuthor = {
            id: 'author-new-' + String(this.nextId),
            email,
            ...(name === '' ? {} : { name }),
            label,
            member_set: true
          };
          this.authors.push(author);
          return ok(author, 201);
        }
      ],
      [
        'PUT',
        'commit_authors/:',
        ([id], b) => {
          const a = this.authors.find((x) => x.id === id);
          if (a === undefined) return notFound();
          const label = oneOf(Object.values(AuthorLabel), field(b, 'label'));
          if (label === undefined) return err(422, 'label', 'Choose one of: yours, your_fleet.', 'label');
          a.label = label;
          a.member_set = true;
          return ok(a);
        }
      ],
      [
        'DELETE',
        'commit_authors/:',
        ([id]) => {
          const i = this.authors.findIndex((x) => x.id === id);
          if (i < 0) return notFound();
          this.authors.splice(i, 1);
          return { status: 204 };
        }
      ]
    ];
  }
}
