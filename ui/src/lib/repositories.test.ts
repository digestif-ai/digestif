import { describe, expect, it } from 'vitest';
import {
  AuthorLabel,
  FoundBy,
  OrganizationChoice,
  RepositoryStatus,
  type Organization,
  type Repository
} from '#generated/com-bryzek-digestif-node.ts';
import {
  REPOSITORY_PAGE,
  chipCountOf,
  choiceOf,
  controlsOf,
  cursorOf,
  effectiveStatus,
  foundLine,
  isEmptyPlan,
  isNewOrganization,
  nextTrail,
  pageStart,
  previousTrail,
  repositoryPage,
  rowControl,
  savePlan,
  toggled,
  withRecommended
} from './repositories.ts';
import { organizationsUrl, repositoriesUrl } from './api/repositories.ts';

const repo = (id: string, status: RepositoryStatus): Repository => ({
  id,
  organization_id: 'o',
  name: id,
  status,
  found_at: '2026-01-01T00:00:00Z',
  clone_count: 1
});

describe('repositories', () => {
  it('pages by cursor: Next reads after the last row, Previous goes back a page (ISS-41944)', () => {
    const rows = Array.from({ length: REPOSITORY_PAGE + 1 }, (_, i) => repo('r' + String(i), RepositoryStatus.Approved));
    const first = repositoryPage([], rows);
    expect(first.rows).toHaveLength(REPOSITORY_PAGE);
    expect(first.more).toBe(true);
    expect(pageStart(first)).toBe(0);
    expect(cursorOf(first.trail)).toBeUndefined();
    const second = repositoryPage(nextTrail(first), rows.slice(0, 3));
    expect(cursorOf(second.trail)).toBe('r' + String(REPOSITORY_PAGE - 1));
    expect(pageStart(second)).toBe(REPOSITORY_PAGE);
    expect(second.more).toBe(false);
    expect(previousTrail(second)).toEqual([]);
  });

  it('asks for a page by cursor, never by offset with one', () => {
    expect(repositoriesUrl({ limit: 11, cursor: 'github.com/o/a', offset: 20 })).toContain('cursor=github.com%2Fo%2Fa');
    expect(repositoriesUrl({ limit: 11, cursor: 'x', offset: 20 })).not.toContain('offset');
    expect(repositoriesUrl({ limit: 11 })).not.toContain('cursor');
    expect(organizationsUrl({ limit: 21 })).toMatch(/organizations\?limit=21$/);
    expect(organizationsUrl({ limit: 21, cursor: 'local:~/a' })).toContain('cursor=local%3A%7E%2Fa');
  });

  it('maps each choice to the two controls and back', () => {
    for (const c of Object.values(OrganizationChoice)) expect(choiceOf(controlsOf(c))).toBe(c);
    expect(choiceOf({ all: false, automatic: true })).toBe(OrganizationChoice.Chosen);
  });

  it('shows what All will approve, and a staged status over everything', () => {
    const undecided = repo('a', RepositoryStatus.Undecided);
    const declined = repo('b', RepositoryStatus.Declined);
    const none = new Map<string, RepositoryStatus>();
    expect(effectiveStatus(undecided, none, OrganizationChoice.All)).toBe(RepositoryStatus.Approved);
    expect(effectiveStatus(undecided, none, OrganizationChoice.Chosen)).toBe(RepositoryStatus.Undecided);
    expect(effectiveStatus(undecided, none, undefined)).toBe(RepositoryStatus.Undecided);
    expect(effectiveStatus(declined, none, OrganizationChoice.AllAutomatic)).toBe(RepositoryStatus.Declined);
    expect(effectiveStatus(declined, new Map([['b', RepositoryStatus.Approved]]), undefined)).toBe(RepositoryStatus.Approved);
  });

  it('unchecking declines', () => {
    expect(toggled(false)).toBe(RepositoryStatus.Declined);
    expect(toggled(true)).toBe(RepositoryStatus.Approved);
  });

  it('drops what was staged back to what the node holds', () => {
    const authors = [{ id: 'x', email: 'x@example.com', label: AuthorLabel.Yours, member_set: false }];
    const plan = savePlan({
      choices: new Map([
        ['o', OrganizationChoice.All],
        ['p', OrganizationChoice.Chosen]
      ]),
      currentChoices: new Map([
        ['o', OrganizationChoice.Chosen],
        ['p', OrganizationChoice.Chosen]
      ]),
      statuses: new Map([
        ['a', RepositoryStatus.Approved],
        ['b', RepositoryStatus.Declined]
      ]),
      currentStatuses: new Map([
        ['a', RepositoryStatus.Approved],
        ['b', RepositoryStatus.Approved]
      ]),
      authors,
      labels: new Map([['x', AuthorLabel.YourFleet]]),
      removed: new Set(['x']),
      added: []
    });
    expect(plan.organizations).toEqual([['o', OrganizationChoice.All]]);
    expect(plan.repositories).toEqual([['b', RepositoryStatus.Declined]]);
    expect(plan.removeAuthors).toEqual(['x']);
    expect(plan.labelAuthors).toEqual([]);
    expect(isEmptyPlan(plan)).toBe(false);
  });

  it('counts each chip from GET /repositories/counts, All as their sum, and nothing before they arrive', () => {
    const counts = [
      { status: RepositoryStatus.Approved, count: 4 },
      { status: RepositoryStatus.Declined, count: 1 }
    ];
    expect(chipCountOf(undefined, undefined)).toBeUndefined();
    expect(chipCountOf(undefined, RepositoryStatus.Approved)).toBeUndefined();
    expect(chipCountOf(counts, undefined)).toBe(5);
    expect(chipCountOf(counts, RepositoryStatus.Approved)).toBe(4);
    expect(chipCountOf(counts, RepositoryStatus.Undecided)).toBe(0);
  });
});

// DES-37153, the Undecided view.
describe('the Undecided view', () => {
  const found = (id: string, extra: Partial<Repository> = {}): Repository => ({
    ...repo(id, RepositoryStatus.Undecided),
    found_by: FoundBy.NewClone,
    ...extra
  });
  const org = (repositories: number, choice = OrganizationChoice.Chosen): Organization => ({ id: 'o', name: 'acme', choice, repositories });

  it('an organization is new when it is Chosen and every repository in it was found later and waits undecided', () => {
    expect(isNewOrganization(org(2), repositoryPage([], [found('a'), found('b')]))).toBe(true);
    expect(isNewOrganization(org(2, OrganizationChoice.All), repositoryPage([], [found('a'), found('b')]))).toBe(false);
    // One of setup's, one decided, or a page that does not hold the whole organization.
    expect(isNewOrganization(org(2), repositoryPage([], [found('a'), repo('b', RepositoryStatus.Undecided)]))).toBe(false);
    expect(isNewOrganization(org(2), repositoryPage([], [found('a'), { ...found('b'), status: RepositoryStatus.Declined }]))).toBe(false);
    expect(isNewOrganization(org(3), repositoryPage([], [found('a'), found('b')]))).toBe(false);
    expect(isNewOrganization(org(2), repositoryPage(['x'], [found('a'), found('b')]))).toBe(false);
  });

  it('the where-and-how line names the clones, how it turned up and the member’s last commit', () => {
    const at = '2026-11-06T15:00:00Z';
    expect(foundLine(found('a', { found_at: at, clone_count: 5, last_own_commit_at: '2026-11-05T15:00:00Z' }))).toBe(
      '5 clones · new clone, Nov 6 note time · your last commit Nov 5'
    );
    expect(foundLine(found('a', { found_at: at, found_by: FoundBy.NewRemote }))).toBe(
      '1 clone · new remote on a scanned folder, Nov 6 note time · no commit of yours'
    );
    expect(foundLine({ ...repo('a', RepositoryStatus.Undecided), found_at: at })).toBe(
      '1 clone · found at setup, Nov 6 · no commit of yours'
    );
  });

  it('an undecided row takes the select, except where a new organization’s All decides it', () => {
    const r = found('a');
    expect(rowControl(repo('d', RepositoryStatus.Approved), false, OrganizationChoice.Chosen)).toBe('checkbox');
    expect(rowControl(r, false, OrganizationChoice.All)).toBe('select');
    expect(rowControl(r, true, OrganizationChoice.Chosen)).toBe('select');
    expect(rowControl(r, true, OrganizationChoice.All)).toBe('status');
    expect(rowControl(r, true, OrganizationChoice.AllAutomatic)).toBe('status');
  });

  it('Save with nothing changed takes every recommended answer, and keeps what the member staged', () => {
    const fresh: Organization = { id: 'f', name: 'f', choice: OrganizationChoice.Chosen, repositories: 1 };
    const known: Organization = { id: 'k', name: 'k', choice: OrganizationChoice.Chosen, repositories: 3 };
    const pages = {
      f: repositoryPage([], [{ ...found('f1'), organization_id: 'f' }]),
      k: repositoryPage([], [found('k1'), found('k2'), repo('k3', RepositoryStatus.Declined)])
    };
    const out = withRecommended({
      organizations: [fresh, known],
      pages,
      fresh: new Set(['f']),
      choices: new Map(),
      statuses: new Map([['k2', RepositoryStatus.Undecided]])
    });
    expect([...out.choices]).toEqual([['f', OrganizationChoice.All]]);
    expect(out.statuses.get('k1')).toBe(RepositoryStatus.Approved);
    expect(out.statuses.get('k2')).toBe(RepositoryStatus.Undecided);
    expect(out.statuses.has('k3')).toBe(false);
    expect(out.statuses.has('f1')).toBe(false);

    const chosen = withRecommended({
      organizations: [fresh],
      pages,
      fresh: new Set(['f']),
      choices: new Map([['f', OrganizationChoice.Chosen]]),
      statuses: new Map()
    });
    expect(chosen.statuses.get('f1')).toBe(RepositoryStatus.Approved);
  });
});
