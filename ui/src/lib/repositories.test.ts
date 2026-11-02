import { describe, expect, it } from 'vitest';
import { AuthorLabel, OrganizationChoice, RepositoryStatus, type Repository } from '#generated/com-bryzek-digestif-node.ts';
import { choiceOf, controlsOf, effectiveStatus, isEmptyPlan, savePlan, toggled } from './repositories.ts';

const repo = (id: string, status: RepositoryStatus): Repository => ({
  id,
  organization_id: 'o',
  name: id,
  status,
  found_at: '2026-01-01T00:00:00Z'
});

describe('repositories', () => {
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
});
