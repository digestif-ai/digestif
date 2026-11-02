<script lang="ts">
  import { goto } from '$app/navigation';
  import { createClient } from '#lib/api/client.ts';
  import Button from '#lib/components/Button.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import { relativeTime } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import { Submission } from '#lib/submission.svelte.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const entry = $derived(data.entry);

  const client = createClient();
  const submission = new Submission();
  let confirming = $state(false);

  async function handleRemove(): Promise<void> {
    await submission.run(
      () => client.removeDeny(entry.id),
      () => goto(href.denyList(), { refreshAll: true })
    );
  }
</script>

<PageHeader
  title={entry.value}
  crumbs={[
    { label: 'Settings', href: href.settings() },
    { label: 'Deny list', href: href.denyList() }
  ]}
/>
<ErrorBanner errors={submission.errors} />

<section class="dg-card p-4">
  <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
    <dt class="dg-muted">Kind</dt>
    <dd>{entry.kind}</dd>
    <dt class="dg-muted">Value</dt>
    <dd class="font-mono break-all">{entry.value}</dd>
    <dt class="dg-muted">Refused</dt>
    <dd>{entry.trips} {entry.trips === 1 ? 'message' : 'messages'}</dd>
    <dt class="dg-muted">Added</dt>
    <dd>{relativeTime(entry.created_at)}</dd>
  </dl>
</section>

<div class="mt-6 border-t border-stone-200 pt-4 dark:border-stone-800">
  {#if confirming}
    <p class="mb-2 text-sm">Remove this entry? Messages matching it will no longer be refused.</p>
    <div class="flex gap-2">
      <Button variant="danger" busy={submission.busy() && 'Removing…'} onclick={handleRemove}>Remove</Button>
      <Button onclick={() => (confirming = false)} disabled={submission.busy()}>Cancel</Button>
    </div>
  {:else}
    <button type="button" class="min-h-11 text-sm text-red-700 hover:underline dark:text-red-300" onclick={() => (confirming = true)}
      >Remove from deny list</button
    >
  {/if}
</div>
