<script lang="ts">
  import Empty from '#lib/components/Empty.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import { logLine, noteDate, relativeTime } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import Tabs from '../Tabs.svelte';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
</script>

<PageHeader title="{noteDate(data.note.written_at)} Note" crumbs={[{ label: 'Notes', href: href.notes() }]} />
<Tabs id={data.note.id} current="log" />
<ul class="dg-card dg-rows" aria-label="Log">
  {#each data.log as entry, i (i)}
    <li class="flex flex-wrap justify-between gap-2 px-4 py-3 text-sm" data-testid="log-entry">
      <span>{logLine(entry)}</span>
      <span class="dg-muted text-xs">{relativeTime(entry.at)}</span>
    </li>
  {:else}
    <li><Empty text="Nothing yet" /></li>
  {/each}
</ul>
