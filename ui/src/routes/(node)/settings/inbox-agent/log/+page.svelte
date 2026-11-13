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

<PageHeader
  title="Inbox agent log"
  crumbs={[
    { label: 'Settings', href: href.settings() },
    { label: 'Inbox agent', href: href.inboxAgent() }
  ]}
/>

{#if log.cannot_run}
  <p class="dg-card mb-4 p-4 text-sm text-amber-800 dark:text-amber-300" data-testid="inbox-agent-log-status">{log.cannot_run}</p>
{/if}
{#if log.lines.length === 0}
  <p class="dg-muted text-sm" data-testid="inbox-agent-log-empty">No run has written to the log yet.</p>
{:else}
  <pre class="dg-card overflow-x-auto p-4 text-xs break-words whitespace-pre-wrap" data-testid="inbox-agent-log">{log.lines.join(
      '\n'
    )}</pre>
{/if}
