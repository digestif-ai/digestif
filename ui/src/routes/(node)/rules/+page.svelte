<script lang="ts">
  import { refreshAll } from '$app/navigation';
  import { createClient } from '#lib/api/client.ts';
  import { DenyEntryKind } from '#generated/com-bryzek-digestif-node.ts';
  import Button from '#lib/components/Button.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import { alwaysOn } from '#lib/always-on.ts';
  import { relativeTime } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import { Submission } from '#lib/submission.svelte.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();

  const KINDS: DenyEntryKind[] = [DenyEntryKind.Name, DenyEntryKind.Domain, DenyEntryKind.Id, DenyEntryKind.Pattern];
  const client = createClient();
  const submission = new Submission();
  let adding = $state(false);
  let kind = $state<DenyEntryKind>(DenyEntryKind.Name);
  let value = $state('');

  async function handleAdd(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    await submission.run(
      () => client.addDeny(kind, value),
      async () => {
        value = '';
        adding = false;
        await refreshAll();
      }
    );
  }
</script>

<PageHeader title="Rules">
  {#snippet actions()}
    <Button href={href.rulesEdit()}>Edit rules</Button>
  {/snippet}
</PageHeader>

<section class="dg-card p-4">
  <h2 class="dg-label mb-2">What your agent may and may not share</h2>
  <p class="whitespace-pre-wrap" data-testid="rules-text">{data.rules.text}</p>
  {#if data.rules.updated_at}<p class="dg-muted mt-3 text-xs">Updated {relativeTime(data.rules.updated_at)}</p>{/if}
</section>

<h2 class="dg-label mt-6 mb-2">Always on</h2>
<section class="dg-card p-4" data-testid="always-on-rule" aria-label={alwaysOn.title}>
  <h3 class="mb-2 font-medium">{alwaysOn.title}</h3>
  {#each alwaysOn.paragraphs as paragraph (paragraph)}
    <p class="mt-2 text-sm">{paragraph}</p>
  {/each}
</section>

<div class="mt-6 mb-2 flex items-center justify-between gap-3">
  <h2 class="dg-label">Quiet hours</h2>
  <Button href={href.quietHours()}>Edit quiet hours</Button>
</div>
<section class="dg-card p-4" data-testid="quiet-hours">
  {#if data.rules.quiet_hours}
    <p class="text-sm">{data.rules.quiet_hours.start} to {data.rules.quiet_hours.end}</p>
    {#if data.rules.quiet_hours.active && data.rules.quiet_hours.ends_at}
      <p class="dg-muted mt-1 text-xs">Quiet now, ends {relativeTime(data.rules.quiet_hours.ends_at)}</p>
    {/if}
  {:else}
    <p class="dg-muted text-sm">None</p>
  {/if}
</section>

<div class="mt-6 mb-2 flex items-center justify-between gap-3">
  <h2 class="dg-label">Deny list</h2>
  {#if !adding}<Button onclick={() => (adding = true)}>Add</Button>{/if}
</div>

{#if adding}
  <form class="dg-card mb-4 p-4" onsubmit={handleAdd} aria-label="Add a deny entry">
    <ErrorBanner errors={submission.generalErrors(['kind', 'value'])} />
    <div class="flex flex-col gap-3 sm:flex-row">
      <label class="sm:w-40">
        <span class="dg-label mb-1 block">Kind</span>
        <select class="dg-input" bind:value={kind}>
          {#each KINDS as k (k)}<option value={k}>{k}</option>{/each}
        </select>
      </label>
      <label class="flex-1">
        <span class="dg-label mb-1 block">Value</span>
        <input class="dg-input" bind:value />
        {#if submission.fieldError('value')}<span class="mt-1 block text-sm text-red-700 dark:text-red-300"
            >{submission.fieldError('value')}</span
          >{/if}
      </label>
    </div>
    <div class="mt-3 flex gap-2">
      <Button variant="primary" type="submit" busy={submission.busy() && 'Adding…'}>Add</Button>
      <Button onclick={() => (adding = false)} disabled={submission.busy()}>Cancel</Button>
    </div>
  </form>
{:else}
  <ul class="dg-card dg-rows overflow-hidden" aria-label="Deny list">
    {#each data.rules.deny as entry (entry.id)}
      <li>
        <a class="dg-row" href={href.deny(entry.id)} data-testid="deny-row">
          <span class="min-w-0 flex-1 truncate font-mono text-sm">{entry.value}</span>
          <span class="dg-muted text-sm">{entry.kind}</span>
        </a>
      </li>
    {:else}
      <li class="dg-muted px-4 py-6 text-center text-sm">No entries</li>
    {/each}
  </ul>
{/if}

<h2 class="dg-label mt-6 mb-2">Built-in detectors</h2>
<ul class="dg-card dg-rows overflow-hidden">
  {#each data.rules.detectors as detector (detector.name)}
    <li class="px-4 py-3">
      <p class="text-sm font-medium">{detector.name}</p>
      <p class="dg-muted text-xs">{detector.description}</p>
    </li>
  {/each}
</ul>
