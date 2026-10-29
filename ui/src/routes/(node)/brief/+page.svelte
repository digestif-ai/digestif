<script lang="ts">
  import Button from '#lib/components/Button.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import { relativeTime } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
</script>

<PageHeader title="My brief">
  {#snippet actions()}
    <Button href={href.briefEdit()}>Edit</Button>
  {/snippet}
</PageHeader>

<section class="dg-card p-4">
  {#if data.brief.text === ''}
    <p class="dg-muted text-sm">No brief yet. Your agent knows nothing about you until you write one.</p>
  {:else}
    <p class="whitespace-pre-wrap" data-testid="brief-text">{data.brief.text}</p>
    {#if data.brief.updated_at}<p class="dg-muted mt-3 text-xs">Updated {relativeTime(data.brief.updated_at)}</p>{/if}
  {/if}
</section>
