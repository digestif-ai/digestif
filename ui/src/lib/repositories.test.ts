import { describe, expect, it } from 'vitest';
import { AuthorLabel, OrganizationChoice, RepositoryStatus, type Repository } from '#generated/com-bryzek-digestif-node.ts';
import {
  REPOSITORY_PAGE,
  chipCountOf,
  choiceOf,
  controlsOf,
  cursorOf,
  effectiveStatus,
  isEmptyPlan,
  nextTrail,
  pageStart,
  previousTrail,
  repositoryPage,
  savePlan,
  toggled
} from './repositories.ts';
import { organizationsUrl, repositoriesUrl } from './api/repositories.ts';

const repo = (id: string, status: RepositoryStatus): Repository => ({
  id,
  organization_id: 'o',
  name: id,
  status,
  found_at: '2026-01-01T00:00:00Z'
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
