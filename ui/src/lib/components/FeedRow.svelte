<script lang="ts">
  import { type FeedItem, Voice } from '#generated/com-bryzek-digestif-node.ts';
  import { messageStatus, relativeTime, speaker } from '../format.ts';
  import ReviewLine from './ReviewLine.svelte';
  import StatusBadge from './StatusBadge.svelte';

  interface Props {
    item: FeedItem;
    href: string;
  }

  let { item, href }: Props = $props();
</script>

{#if item.status_note}
  <!-- A status note is one muted line under the agent that sent it, never a card. -->
  <li class="px-4 py-2 text-sm" data-testid="feed-status-note">
    <span class="font-medium">{speaker(Voice.Agent, item.author)}</span>
    <p class="dg-muted text-xs">{item.status_note_words} · {relativeTime(item.created_at)}</p>
  </li>
{:else}
  <li>
    <a class="dg-row" {href} data-testid="feed-row">
      <div class="min-w-0 flex-1">
        <div class="flex flex-wrap items-baseline gap-x-2 text-sm">
          <span class="font-medium">{speaker(item.voice, item.author)}</span>
          {#if item.kind !== 'summary'}<span class="dg-muted">{item.kind}</span>{/if}
          <span class="dg-muted ml-auto text-xs">{relativeTime(item.created_at)}</span>
        </div>
        <p class="truncate text-sm text-stone-700 dark:text-stone-300">{item.preview}</p>
      </div>
      {#if item.status !== 'posted'}<StatusBadge status={messageStatus(item.status)} />{/if}
    </a>
    <!-- Outside the row's link: its own links open what the review names, not the note. -->
    <ReviewLine reviewedAt={item.reviewed_at} review={item.review} class="-mt-2 px-4 pb-3" />
  </li>
{/if}
