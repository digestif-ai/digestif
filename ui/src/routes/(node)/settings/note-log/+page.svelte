<script lang="ts">
  import PageHeader from '#lib/components/PageHeader.svelte';
  import { href } from '#lib/href.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const log = $derived(data.log);
</script>

<PageHeader title="Nightly note log" crumbs={[{ label: 'Settings', href: href.settings() }]} />

{#each log.failures as failure (failure)}
  <p class="dg-card mb-4 p-4 text-sm break-words text-amber-800 dark:text-amber-300" data-testid="note-log-failure">{failure}</p>
{/each}
{#if log.lines.length === 0}
  <p class="dg-muted text-sm" data-testid="note-log-empty">No run has written to the log yet.</p>
{:else}
  <pre class="dg-card overflow-x-auto p-4 text-xs break-words whitespace-pre-wrap" data-testid="note-log">{log.lines.join('\n')}</pre>
{/if}
