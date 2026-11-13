<script lang="ts">
  import Empty from '#lib/components/Empty.svelte';
  import FeedRow from '#lib/components/FeedRow.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import { speaker } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import type { PageData } from './$types';

  // A Feed thread: every message about one thing, oldest first, each opening its own page.
  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const first = $derived(data.messages[0]);
</script>

<PageHeader title={first === undefined ? 'Thread' : speaker(first.voice, first.author)} crumbs={[{ label: 'Feed', href: href.feed() }]} />
<ul class="dg-card dg-rows overflow-hidden" aria-label="Thread">
  {#each data.messages as item (item.hash)}
    <FeedRow {item} href={href.message(item.hash)} />
  {:else}
    <Empty text="Nothing in this thread" />
  {/each}
</ul>
