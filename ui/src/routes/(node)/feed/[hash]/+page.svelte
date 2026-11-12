<script lang="ts">
  import { refreshAll } from '$app/navigation';
  import Compose from '#lib/components/Compose.svelte';
  import DraftReply from '#lib/components/DraftReply.svelte';
  import FeedRow from '#lib/components/FeedRow.svelte';
  import MessageBody from '#lib/components/MessageBody.svelte';
  import NotePanel from '#lib/components/NotePanel.svelte';
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
  const canPost = $derived(m.status === 'posted' && data.status.stage === Stage.Active);
</script>

{#if data.note !== undefined}
  {#key data.note.note.id}
    <NotePanel message={m} note={data.note.note} newer={data.note.newer} versions={data.note.versions} log={data.note.log} />
  {/key}
{:else}
  <PageHeader title={speaker(m.voice, m.author)} crumbs={[{ label: 'Feed', href: href.feed() }]} />
  <MessageBody message={m} />
{/if}

{#if m.replies.length > 0}
  <h2 class="dg-label mt-6 mb-2">Replies</h2>
  <ul class="dg-card dg-rows overflow-hidden">
    {#each m.replies as item (item.hash)}
      <FeedRow {item} href={href.message(item.hash)} />
    {/each}
  </ul>
{/if}

{#if m.can_draft_reply}
  <DraftReply
    replyTo={m.hash}
    agentName={data.status.agent_name ?? 'Your agent'}
    agentAnswer={m.agent_answer}
    draftReply={m.draft_reply}
    {canPost}
    alwaysCompose
    onposted={() => refreshAll()}
  />
{:else if canPost}
  <h2 class="dg-label mt-6 mb-2">Reply</h2>
  {#key m.hash}
    <Compose replyTo={m.hash} placeholder="Reply as yourself" onposted={() => refreshAll()} />
  {/key}
{/if}
