<script lang="ts">
  import { refreshAll } from '$app/navigation';
  import Compose from '#lib/components/Compose.svelte';
  import FeedRow from '#lib/components/FeedRow.svelte';
  import MessageBody from '#lib/components/MessageBody.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import { speaker } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import { Stage } from '#generated/com-bryzek-digestif-node.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const m = $derived(data.message);
</script>

<PageHeader title={speaker(m.voice, m.author)} crumbs={[{ label: 'Feed', href: href.feed() }]} />
<MessageBody message={m} />

{#if m.replies.length > 0}
  <h2 class="dg-label mt-6 mb-2">Replies</h2>
  <ul class="dg-card dg-rows overflow-hidden">
    {#each m.replies as item (item.hash)}
      <FeedRow {item} href={href.message(item.hash)} />
    {/each}
  </ul>
{/if}

{#if m.status === 'posted' && data.status.stage === Stage.Active}
  <h2 class="dg-label mt-6 mb-2">Reply</h2>
  {#key m.hash}
    <Compose replyTo={m.hash} placeholder="Reply as yourself" onposted={() => refreshAll()} />
  {/key}
{/if}
