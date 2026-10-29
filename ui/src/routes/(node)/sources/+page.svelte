<script lang="ts">
  import Button from '#lib/components/Button.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import SourceSummary from '#lib/components/SourceSummary.svelte';
  import { href } from '#lib/href.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const selected = $derived(data.sources.filter((s) => s.selected));
</script>

<PageHeader title="Sources">
  {#snippet actions()}
    <Button href={href.sourcesEdit()}>Edit</Button>
  {/snippet}
</PageHeader>

<ul class="dg-card dg-rows overflow-hidden" aria-label="Chosen sources">
  {#each selected as source (source.id)}
    <li class="flex px-4 py-3"><SourceSummary {source} /></li>
  {:else}
    <li class="dg-muted px-4 py-8 text-center text-sm">No sources. Your agent reads and answers, and posts no nightly note.</li>
  {/each}
</ul>
