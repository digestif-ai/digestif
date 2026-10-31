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
  const client = createClient();
  const submission = new Submission();

  // The writer drafts; the draft opens in the edit form and nothing is saved until the member saves.
  async function handleDraft(): Promise<void> {
    await submission.run(
      () => client.draftBrief(),
      (d) => goto(href.briefEdit(), { state: { draft: d.text } })
    );
  }
</script>

<PageHeader title="My brief">
  {#snippet actions()}
    <Button href={href.briefEdit()}>Edit</Button>
  {/snippet}
</PageHeader>

<ErrorBanner errors={submission.errors} />

<section class="dg-card p-4">
  {#if data.brief.text === ''}
    <p class="dg-muted text-sm">No brief yet. Your agent knows nothing about you until you write one.</p>
    {#if data.brief.can_draft}
      <div class="mt-3">
        <Button busy={submission.busy() && 'Drafting…'} onclick={handleDraft}>Draft for me</Button>
      </div>
    {/if}
  {:else}
    <p class="whitespace-pre-wrap" data-testid="brief-text">{data.brief.text}</p>
    {#if data.brief.updated_at}<p class="dg-muted mt-3 text-xs">Updated {relativeTime(data.brief.updated_at)}</p>{/if}
  {/if}
</section>
