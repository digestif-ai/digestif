// The repositories page's rules (DES-37265, Repositories), kept out of the component so they are
// tested on their own. The page stages every change and Save sends them; nothing here talks to the
// node.
import {
  AuthorLabel,
  OrganizationChoice,
  RepositoryStatus,
  type CommitAuthor,
  type CommitAuthorForm,
  type Repository
} from '#generated/com-bryzek-digestif-node.ts';
import type { StatusLabel } from './format.ts';

/** The page's two controls per organization: All or Chosen, and under All whether new ones are read automatically. */
export interface ChoiceControls {
  all: boolean;
  automatic: boolean;
}

export function controlsOf(choice: OrganizationChoice): ChoiceControls {
  return { all: choice !== OrganizationChoice.Chosen, automatic: choice === OrganizationChoice.AllAutomatic };
}

export function choiceOf(controls: ChoiceControls): OrganizationChoice {
  if (!controls.all) return OrganizationChoice.Chosen;
  return controls.automatic ? OrganizationChoice.AllAutomatic : OrganizationChoice.All;
}

/**
 * What a repository will be once the staged changes are saved: its own staged status, else
 * approved when it is undecided and its organization is being switched to All (which approves
 * every repository not declined), else what the node says.
 */
export function effectiveStatus(
  repository: Repository,
  staged: Map<string, RepositoryStatus>,
  orgChoice: OrganizationChoice | undefined
): RepositoryStatus {
  const own = staged.get(repository.id);
  if (own !== undefined) return own;
  if (orgChoice !== undefined && orgChoice !== OrganizationChoice.Chosen && repository.status === RepositoryStatus.Undecided) {
    return RepositoryStatus.Approved;
  }
  return repository.status;
}

/** Checking approves; unchecking declines, under All as under Chosen, and keeps the choice. */
export function toggled(checked: boolean): RepositoryStatus {
  return checked ? RepositoryStatus.Approved : RepositoryStatus.Declined;
}

export function statusLabel(status: RepositoryStatus): StatusLabel {
  switch (status) {
    case RepositoryStatus.Approved:
      return { label: 'Approved', tone: 'good' };
    case RepositoryStatus.Declined:
      return { label: 'Declined', tone: 'neutral' };
    case RepositoryStatus.Undecided:
      return { label: 'Undecided', tone: 'warn' };
  }
}

export function authorLabelText(label: AuthorLabel): string {
  return label === AuthorLabel.Yours ? 'Yours' : 'Your fleet';
}

/** Everything Save sends, in the order it sends it. */
export interface SavePlan {
  organizations: [string, OrganizationChoice][];
  repositories: [string, RepositoryStatus][];
  removeAuthors: string[];
  labelAuthors: [string, AuthorLabel][];
  addAuthors: CommitAuthorForm[];
}

/**
 * Organizations first, since choosing All approves what is undecided in it and a repository's own
 * change must land after; then repositories. A repository staged back to what the node already
 * holds, an organization staged back to its own choice, and a label change on an author being
 * removed are dropped.
 */
export function savePlan(input: {
  choices: Map<string, OrganizationChoice>;
  currentChoices: Map<string, OrganizationChoice>;
  statuses: Map<string, RepositoryStatus>;
  currentStatuses: Map<string, RepositoryStatus>;
  authors: CommitAuthor[];
  labels: Map<string, AuthorLabel>;
  removed: Set<string>;
  added: CommitAuthorForm[];
}): SavePlan {
  const organizations = [...input.choices].filter(([id, c]) => input.currentChoices.get(id) !== c);
  const repositories = [...input.statuses].filter(([id, s]) => input.currentStatuses.get(id) !== s);
  const byId = new Map(input.authors.map((a) => [a.id, a]));
  const removeAuthors = [...input.removed].filter((id) => byId.has(id));
  const labelAuthors = [...input.labels].filter(([id, l]) => !input.removed.has(id) && byId.get(id)?.label !== l);
  return { organizations, repositories, removeAuthors, labelAuthors, addAuthors: input.added };
}

export function isEmptyPlan(plan: SavePlan): boolean {
  return (
    plan.organizations.length + plan.repositories.length + plan.removeAuthors.length + plan.labelAuthors.length + plan.addAuthors.length ===
    0
  );
}

/** Repositories shown per organization before its pager. */
export const REPOSITORY_PAGE = 10;
