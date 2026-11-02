<script lang="ts">
  import { goto } from '$app/navigation';
  import { isApiError, type ApiResponse } from '#lib/api/client.ts';
  import { createRepositoriesClient } from '#lib/api/repositories.ts';
  import {
    AuthorLabel,
    OrganizationChoice,
    RepositoryStatus,
    type CommitAuthorForm,
    type NodeError,
    type Repository
  } from '#generated/com-bryzek-digestif-node.ts';
  import Button from '#lib/components/Button.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import StatusBadge from '#lib/components/StatusBadge.svelte';
  import { href } from '#lib/href.ts';
  import {
    REPOSITORY_PAGE,
    authorLabelText,
    choiceOf,
    controlsOf,
    effectiveStatus,
    isEmptyPlan,
    savePlan,
    statusLabel,
    toggled
  } from '#lib/repositories.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const client = createRepositoriesClient();
  const back = href.sources();

  // Every change is staged here and sent by Save; Cancel drops them.
  let choices = $state(new Map<string, OrganizationChoice>());
  let statuses = $state(new Map<string, RepositoryStatus>());
  let labels = $state(new Map<string, AuthorLabel>());
  let removed = $state(new Set<string>());
  let added = $state<CommitAuthorForm[]>([]);
  // What the node held for each repository the page has shown, so a change staged back is dropped.
  const seen = new Map<string, RepositoryStatus>();

  interface Page {
    offset: number;
    rows: Repository[];
    more: boolean;
  }

  function pageOf(offset: number, rows: Repository[]): Page {
    for (const r of rows) seen.set(r.id, r.status);
    return { offset, rows: rows.slice(0, REPOSITORY_PAGE), more: rows.length > REPOSITORY_PAGE };
  }

  // svelte-ignore state_referenced_locally
  let pages = $state<Record<string, Page>>(Object.fromEntries(Object.entries(data.firstPages).map(([id, rows]) => [id, pageOf(0, rows)])));

  let q = $state('');
  let status = $state<RepositoryStatus | undefined>(undefined);
  const filtered = $derived(q.trim() !== '' || status !== undefined);
  let loadErrors = $state<NodeError[]>([]);

  async function loadOrg(id: string, offset: number): Promise<void> {
    const response = await client.repositories({ q, status, organizationId: id, limit: REPOSITORY_PAGE + 1, offset });
    if (isApiError(response)) loadErrors = response.errors;
    else pages[id] = pageOf(offset, response.data);
  }

  async function reloadAll(): Promise<void> {
    loadErrors = [];
    await Promise.all(data.organizations.map((o) => loadOrg(o.id, 0)));
  }

  let searchTimer: ReturnType<typeof setTimeout> | undefined;
  function handleSearch(): void {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => void reloadAll(), 250);
  }

  function handleStatus(s: RepositoryStatus | undefined): void {
    status = s;
    void reloadAll();
  }

  const currentChoices = $derived(new Map(data.organizations.map((o) => [o.id, o.choice])));
  const choiceFor = (id: string): OrganizationChoice => choices.get(id) ?? currentChoices.get(id) ?? OrganizationChoice.Chosen;

  function setControls(id: string, all: boolean, automatic: boolean): void {
    choices.set(id, choiceOf({ all, automatic }));
    choices = new Map(choices);
  }

  function statusOf(r: Repository): RepositoryStatus {
    const staged = choices.get(r.organization_id);
    return effectiveStatus(r, statuses, staged);
  }

  function handleToggle(r: Repository, checked: boolean): void {
    statuses.set(r.id, toggled(checked));
    statuses = new Map(statuses);
  }

  function handleLabel(id: string, label: AuthorLabel): void {
    labels.set(id, label);
    labels = new Map(labels);
  }

  function handleRemove(id: string): void {
    removed = new Set([...removed, id]);
  }

  function handleUndoRemove(id: string): void {
    removed = new Set([...removed].filter((x) => x !== id));
  }

  let adding = $state(false);
  let email = $state('');
  let name = $state('');
  let newLabel = $state<AuthorLabel>(AuthorLabel.Yours);
  let addError = $state<string | undefined>(undefined);

  function handleAdd(event: SubmitEvent): void {
    event.preventDefault();
    const e = email.trim().toLowerCase();
    if (e === '') {
      addError = 'Enter an email.';
      return;
    }
    if (data.authors.some((a) => a.email === e && !removed.has(a.id)) || added.some((a) => a.email === e)) {
      addError = 'That email is already an author.';
      return;
    }
    added = [...added, { email: e, ...(name.trim() === '' ? {} : { name: name.trim() }), label: newLabel }];
    email = '';
    name = '';
    newLabel = AuthorLabel.Yours;
    addError = undefined;
    adding = false;
  }

  let saving = $state(false);
  let saveErrors = $state<NodeError[]>([]);

  async function handleSave(): Promise<void> {
    const plan = savePlan({
      choices,
      currentChoices,
      statuses,
      currentStatuses: seen,
      authors: data.authors,
      labels,
      removed,
      added
    });
    if (isEmptyPlan(plan)) {
      await goto(back);
      return;
    }
    saving = true;
    saveErrors = [];
    // Sent one at a time, in the plan's order; the first refusal stops the rest and is shown.
    const steps: (() => Promise<ApiResponse<unknown>>)[] = [
      ...plan.organizations.map(
        ([id, c]) =>
          () =>
            client.setOrganization(id, c)
      ),
      ...plan.repositories.map(
        ([id, s]) =>
          () =>
            client.setRepository(id, s)
      ),
      ...plan.removeAuthors.map((id) => () => client.removeCommitAuthor(id)),
      ...plan.labelAuthors.map(
        ([id, l]) =>
          () =>
            client.labelCommitAuthor(id, l)
      ),
      ...plan.addAuthors.map((f) => () => client.addCommitAuthor(f))
    ];
    try {
      for (const step of steps) {
        const response = await step();
        if (isApiError(response)) {
          saveErrors = response.errors;
          return;
        }
      }
      await goto(back, { invalidateAll: true });
    } finally {
      saving = false;
    }
  }

  const CHIPS: [string, RepositoryStatus | undefined][] = [
    ['All', undefined],
    ['Approved', RepositoryStatus.Approved],
    ['Declined', RepositoryStatus.Declined],
    ['Undecided', RepositoryStatus.Undecided]
  ];
  const total = $derived(data.organizations.reduce((n, o) => n + o.repositories, 0));
  const shown = $derived(
    data.organizations.filter((o) => !filtered || (pages[o.id]?.rows.length ?? 0) > 0 || (pages[o.id]?.offset ?? 0) > 0)
  );
</script>

<PageHeader title="Repositories" crumbs={[{ label: 'Sources', href: back }]} />
<ErrorBanner errors={[...loadErrors, ...saveErrors]} />

<input
  class="dg-input"
  type="search"
  placeholder="Search repositories"
  aria-label="Search repositories"
  bind:value={q}
  oninput={handleSearch}
/>
<div class="mt-3 flex flex-wrap gap-2" role="group" aria-label="Status">
  {#each CHIPS as [label, value] (label)}
    <button
      type="button"
      class="min-h-9 rounded-full border px-3 text-sm {status === value
        ? 'border-transparent bg-dg-accent text-white'
        : 'border-stone-300 bg-white text-stone-700 dark:border-stone-700 dark:bg-stone-900 dark:text-stone-200'}"
      aria-pressed={status === value}
      onclick={() => handleStatus(value)}>{label}{value === undefined ? ' ' + String(total) : ''}</button
    >
  {/each}
</div>

{#each shown as org (org.id)}
  {@const controls = controlsOf(choiceFor(org.id))}
  {@const page = pages[org.id]}
  <section class="mt-6" aria-label={org.name} data-testid="org-{org.name}">
    <h2 class="dg-label mb-2">{org.name}</h2>
    <fieldset class="dg-card dg-rows overflow-hidden">
      <legend class="sr-only">What to read in {org.name}</legend>
      <label class="dg-row cursor-pointer">
        <input
          type="radio"
          name="choice-{org.id}"
          class="size-5 border-stone-400 text-dg-accent focus:ring-dg-accent"
          checked={controls.all}
          onchange={() => setControls(org.id, true, controls.automatic)}
        />
        <span>All repositories in {org.name}</span>
      </label>
      <label class="dg-row cursor-pointer pl-12" class:opacity-60={!controls.all}>
        <input
          type="checkbox"
          class="size-5 rounded border-stone-400 text-dg-accent focus:ring-dg-accent"
          checked={controls.automatic}
          disabled={!controls.all}
          onchange={(e) => setControls(org.id, true, e.currentTarget.checked)}
        />
        <span>Read new repositories automatically</span>
      </label>
      <label class="dg-row cursor-pointer">
        <input
          type="radio"
          name="choice-{org.id}"
          class="size-5 border-stone-400 text-dg-accent focus:ring-dg-accent"
          checked={!controls.all}
          onchange={() => setControls(org.id, false, false)}
        />
        <span>Chosen repositories</span>
      </label>
    </fieldset>

    <div class="dg-card mt-2 overflow-hidden">
      <table class="w-full text-sm">
        <thead class="dg-muted text-left text-xs">
          <tr>
            <th class="w-12 px-4 py-2"><span class="sr-only">Read</span></th>
            <th class="px-2 py-2 font-medium">Repository</th>
            <th class="px-4 py-2 font-medium">Status</th>
          </tr>
        </thead>
        <tbody class="dg-rows border-t border-stone-200 dark:border-stone-800">
          {#each page?.rows ?? [] as repo (repo.id)}
            {@const st = statusOf(repo)}
            <tr data-testid="repo-{repo.name}">
              <td class="px-4 py-2">
                <input
                  type="checkbox"
                  aria-label="Read {repo.name}"
                  class="size-5 rounded border-stone-400 text-dg-accent focus:ring-dg-accent"
                  checked={st === RepositoryStatus.Approved}
                  onchange={(e) => handleToggle(repo, e.currentTarget.checked)}
                />
              </td>
              <td class="px-2 py-2 font-mono break-all">{repo.name}</td>
              <td class="px-4 py-2"><StatusBadge status={statusLabel(st)} /></td>
            </tr>
          {:else}
            <tr><td colspan="3" class="dg-muted px-4 py-4 text-center">No repositories.</td></tr>
          {/each}
        </tbody>
      </table>
      {#if page !== undefined && (page.offset > 0 || page.more)}
        <div class="dg-muted flex items-center justify-between border-t border-stone-200 px-4 py-2 text-sm dark:border-stone-800">
          <span>{page.offset + 1}–{page.offset + page.rows.length}{filtered ? '' : ' of ' + String(org.repositories)}</span>
          <span class="flex gap-2">
            {#if page.offset > 0}<button
                type="button"
                class="dg-link"
                onclick={() => void loadOrg(org.id, Math.max(0, page.offset - REPOSITORY_PAGE))}>Previous</button
              >{/if}
            {#if page.more}<button type="button" class="dg-link" onclick={() => void loadOrg(org.id, page.offset + REPOSITORY_PAGE)}
                >Next</button
              >{/if}
          </span>
        </div>
      {/if}
    </div>
  </section>
{:else}
  <p class="dg-muted mt-6 text-center text-sm">{filtered ? 'No repositories match.' : 'No repositories on this machine.'}</p>
{/each}

<section class="mt-8" aria-label="Commit authors">
  <h2 class="dg-label mb-2">Commit authors</h2>
  <div class="dg-card overflow-hidden">
    <table class="w-full text-sm">
      <thead class="dg-muted text-left text-xs">
        <tr>
          <th class="px-4 py-2 font-medium">Identity</th>
          <th class="px-2 py-2 font-medium">Whose</th>
          <th class="px-4 py-2"><span class="sr-only">Remove</span></th>
        </tr>
      </thead>
      <tbody class="dg-rows border-t border-stone-200 dark:border-stone-800">
        {#each data.authors as author (author.id)}
          {@const gone = removed.has(author.id)}
          <tr data-testid="author-{author.email}" class:opacity-60={gone}>
            <td class="px-4 py-2 break-all" class:line-through={gone}>
              {author.email}{#if author.name !== undefined}<span class="dg-muted block text-xs">{author.name}</span>{/if}
            </td>
            <td class="px-2 py-2">
              <select
                class="dg-input min-w-32 py-1 text-sm"
                aria-label="Whose is {author.email}"
                disabled={gone}
                value={labels.get(author.id) ?? author.label}
                onchange={(e) => handleLabel(author.id, e.currentTarget.value as AuthorLabel)}
              >
                {#each [AuthorLabel.Yours, AuthorLabel.YourFleet] as l (l)}<option value={l}>{authorLabelText(l)}</option>{/each}
              </select>
            </td>
            <td class="px-4 py-2 text-right">
              {#if gone}
                <button type="button" class="dg-link" onclick={() => handleUndoRemove(author.id)}>Undo</button>
              {:else}
                <button type="button" class="dg-link" aria-label="Remove {author.email}" onclick={() => handleRemove(author.id)}
                  >Remove</button
                >
              {/if}
            </td>
          </tr>
        {/each}
        {#each added as author (author.email)}
          <tr data-testid="author-{author.email}">
            <td class="px-4 py-2 break-all">
              {author.email}{#if author.name !== undefined}<span class="dg-muted block text-xs">{author.name}</span>{/if}
            </td>
            <td class="px-2 py-2">{authorLabelText(author.label)}</td>
            <td class="px-4 py-2 text-right">
              <button
                type="button"
                class="dg-link"
                aria-label="Remove {author.email}"
                onclick={() => (added = added.filter((a) => a.email !== author.email))}>Remove</button
              >
            </td>
          </tr>
        {/each}
        {#if data.authors.length === 0 && added.length === 0}
          <tr><td colspan="3" class="dg-muted px-4 py-4 text-center">No commit authors. No commits are read until one is added.</td></tr>
        {/if}
      </tbody>
    </table>
  </div>
  {#if adding}
    <form class="dg-card mt-3 p-4" onsubmit={handleAdd} aria-label="Add identity">
      <div class="flex flex-col gap-3">
        <label>
          <span class="dg-label mb-1 block">Email</span>
          <input class="dg-input" bind:value={email} />
          {#if addError}<span class="mt-1 block text-sm text-red-700 dark:text-red-300">{addError}</span>{/if}
        </label>
        <label>
          <span class="dg-label mb-1 block">Name</span>
          <input class="dg-input" bind:value={name} />
        </label>
        <label>
          <span class="dg-label mb-1 block">Whose</span>
          <select class="dg-input" bind:value={newLabel}>
            {#each [AuthorLabel.Yours, AuthorLabel.YourFleet] as l (l)}<option value={l}>{authorLabelText(l)}</option>{/each}
          </select>
        </label>
      </div>
      <div class="mt-3 flex gap-2">
        <Button variant="primary" type="submit">Add</Button>
        <Button onclick={() => (adding = false)}>Cancel</Button>
      </div>
    </form>
  {:else}
    <div class="mt-3"><Button onclick={() => (adding = true)}>Add identity</Button></div>
  {/if}
</section>

<div class="mt-8 flex justify-end gap-2">
  <Button href={back}>Cancel</Button>
  <Button variant="primary" busy={saving && 'Saving…'} onclick={() => void handleSave()}>Save</Button>
</div>
