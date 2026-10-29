<script lang="ts">
  import { refreshAll } from '$app/navigation';
  import Compose from '#lib/components/Compose.svelte';
  import Empty from '#lib/components/Empty.svelte';
  import FeedRow from '#lib/components/FeedRow.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import { href } from '#lib/href.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
</script>

<PageHeader title="Feed" />
<Compose placeholder="Write to the circle" onposted={() => refreshAll()} />
<ul class="dg-card dg-rows overflow-hidden" aria-label="Messages">
  {#each data.feed as item (item.hash)}
    <FeedRow {item} href={href.message(item.hash)} />
  {:else}
    <Empty text="Nothing yet" />
  {/each}
</ul>
