// The repositories page's rules (DES-37265, Repositories), kept out of the component so they are
// tested on their own. The page stages every change and Save sends them; nothing here talks to the
// node.
import {
  AuthorLabel,
  FoundBy,
  OrganizationChoice,
  RepositoryStatus,
  type CommitAuthor,
  type CommitAuthorForm,
  type Organization,
  type Repository,
  type RepositoryStatusCount
} from '#generated/com-bryzek-digestif-node.ts';
import { noteDate, type StatusLabel } from './format.ts';

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

/** A status chip's count from GET /repositories/counts: one status's, or All's as their sum; none until they arrive. */
export function chipCountOf(counts: RepositoryStatusCount[] | undefined, status: RepositoryStatus | undefined): number | undefined {
  if (counts === undefined) return undefined;
  if (status === undefined) return counts.reduce((n, c) => n + c.count, 0);
  return counts.find((c) => c.status === status)?.count ?? 0;
}

/** Repositories shown per organization before its pager. */
export const REPOSITORY_PAGE = 10;

/** Organizations shown before More organizations. */
export const ORGANIZATION_PAGE = 20;

/**
 * One organization's page of repositories, read by cursor (ISS-41944): [trail] is the cursor each
 * page after the first began after, so the first page's is empty and Previous drops its last.
 */
export interface RepositoryPage {
  trail: string[];
  rows: Repository[];
  more: boolean;
}

/** A page from the rows the node answered, asked for one more than a page so the pager knows whether there is a next. */
export function repositoryPage(trail: string[], rows: Repository[]): RepositoryPage {
  return { trail, rows: rows.slice(0, REPOSITORY_PAGE), more: rows.length > REPOSITORY_PAGE };
}

/** Where the page starts in the list, counting from 0. */
export function pageStart(page: RepositoryPage): number {
  return page.trail.length * REPOSITORY_PAGE;
}

/** The trail Next reads: this one and the page's last row. */
export function nextTrail(page: RepositoryPage): string[] {
  const last = page.rows[page.rows.length - 1];
  return last === undefined ? page.trail : [...page.trail, last.id];
}

/** The trail Previous reads. */
export function previousTrail(page: RepositoryPage): string[] {
  return page.trail.slice(0, -1);
}

/** The cursor a trail reads after; none for the first page. */
export function cursorOf(trail: string[]): string | undefined {
  return trail[trail.length - 1];
}

/**
 * DES-37153, the Undecided view: an organization the member has never once confirmed. The node
 * stores an organization first seen after setup as Chosen repositories with every repository in it
 * undecided and found by a later scan; an organization the member chose at setup holds none found
 * later, and one they have decided anything in holds a decided repository. Judged only on a page
 * holding every repository of the organization, so a search or the pager never decides it.
 */
export function isNewOrganization(organization: Organization, page: RepositoryPage | undefined): boolean {
  if (page === undefined || page.trail.length > 0 || page.more) return false;
  return (
    organization.choice === OrganizationChoice.Chosen &&
    organization.repositories > 0 &&
    page.rows.length === organization.repositories &&
    page.rows.every((r) => r.status === RepositoryStatus.Undecided && r.found_by !== undefined)
  );
}

/** A new organization's three choices, setup's words, the recommended one first and marked. */
export function newOrganizationChoices(name: string): { choice: OrganizationChoice; label: string }[] {
  return [
    { choice: OrganizationChoice.All, label: 'All repositories in ' + name + ', ask me about new ones · Recommended' },
    { choice: OrganizationChoice.AllAutomatic, label: 'All repositories in ' + name + ', new ones read automatically' },
    { choice: OrganizationChoice.Chosen, label: 'Chosen repositories' }
  ];
}

/** What a new organization reads on Save when the member changes nothing. */
export const RECOMMENDED_CHOICE = OrganizationChoice.All;

/** An undecided row's select, Read recommended and first. Undecided is no answer. */
export const READ_ANSWERS: { status: RepositoryStatus; label: string }[] = [
  { status: RepositoryStatus.Approved, label: 'Read · Recommended' },
  { status: RepositoryStatus.Declined, label: "Don't read" },
  { status: RepositoryStatus.Undecided, label: 'Undecided' }
];

/** What an undecided row's select reads on Save when the member changes nothing. */
export const RECOMMENDED_ANSWER = RepositoryStatus.Approved;

/**
 * Each row's control: a decided repository keeps the checkbox; an undecided one gets the select,
 * except under a new organization whose choice is one of the two Alls, where the choice decides
 * every row and the row shows what Save makes it.
 */
export type RowControl = 'checkbox' | 'select' | 'status';

export function rowControl(repository: Repository, newOrganization: boolean, choice: OrganizationChoice): RowControl {
  if (repository.status !== RepositoryStatus.Undecided) return 'checkbox';
  if (newOrganization && choice !== OrganizationChoice.Chosen) return 'status';
  return 'select';
}

/**
 * The where-and-how line under an undecided row: how many clones the machine holds, how it turned
 * up and the note time that found it, and the member's own last commit there.
 */
export function foundLine(repository: Repository): string {
  const clones = repository.clone_count === 1 ? '1 clone' : String(repository.clone_count) + ' clones';
  const when = noteDate(repository.found_at);
  const how =
    repository.found_by === FoundBy.NewClone
      ? 'new clone, ' + when + ' note time'
      : repository.found_by === FoundBy.NewRemote
        ? 'new remote on a scanned folder, ' + when + ' note time'
        : 'found at setup, ' + when;
  const commit =
    repository.last_own_commit_at === undefined ? 'no commit of yours' : 'your last commit ' + noteDate(repository.last_own_commit_at);
  return clones + ' · ' + how + ' · ' + commit;
}

/**
 * Save writes every choice on the page: what the member staged, and for everything they left, the
 * recommended answer. A new organization nobody touched takes All, ask me about new ones; an
 * undecided row with a select nobody touched takes Read. Rows a new organization's All decides
 * take nothing of their own.
 */
export function withRecommended(input: {
  organizations: Organization[];
  pages: Record<string, RepositoryPage | undefined>;
  fresh: Set<string>;
  choices: Map<string, OrganizationChoice>;
  statuses: Map<string, RepositoryStatus>;
}): { choices: Map<string, OrganizationChoice>; statuses: Map<string, RepositoryStatus> } {
  const choices = new Map(input.choices);
  const statuses = new Map(input.statuses);
  for (const o of input.organizations) {
    const fresh = input.fresh.has(o.id);
    if (fresh && !choices.has(o.id)) choices.set(o.id, RECOMMENDED_CHOICE);
    const choice = choices.get(o.id) ?? o.choice;
    for (const r of input.pages[o.id]?.rows ?? []) {
      if (rowControl(r, fresh, choice) === 'select' && !statuses.has(r.id)) statuses.set(r.id, RECOMMENDED_ANSWER);
    }
  }
  return { choices, statuses };
}
