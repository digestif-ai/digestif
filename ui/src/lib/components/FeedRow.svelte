<script lang="ts">
  import { type FeedItem, Voice } from '#generated/ai-digestif-digestif-node.ts';
  import { countLabel, messageStatus, relativeTime, speaker } from '../format.ts';
  import AgentName from './AgentName.svelte';
  import ReviewLine from './ReviewLine.svelte';
  import StatusBadge from './StatusBadge.svelte';

  interface Props {
    item: FeedItem;
    href: string;
    /** How many messages the row's thread holds when it stands for one (ISS-85464); the row opens the thread. */
    count?: number;
    /** How many of them are replies to the note (DIG-128): the count the row names. */
    replies?: number;
  }

  let { item, href, count = 1, replies = 0 }: Props = $props();
  // What an agent wrote is set in monospace, so a person's words read apart (DIG-128).
  const agent = $derived(item.voice !== Voice.Person);
</script>

<!-- A thread says what it counts (DIG-128): its replies, else its messages. -->
{#snippet counted()}
  {#if replies > 0}<span class="dg-muted text-xs" data-testid="thread-count">{countLabel(replies, 'reply', 'replies')}</span
    >{:else if count > 1}<span class="dg-muted text-xs" data-testid="thread-count">{countLabel(count, 'message', 'messages')}</span>{/if}
{/snippet}

{#if item.status_note && count > 1}
  <!-- A thread of waiting days with no note yet: the latest muted line, opening the thread. -->
  <li>
    <a class="block px-4 py-2 text-sm hover:bg-stone-50 dark:hover:bg-stone-900" {href} data-testid="feed-status-note">
      <span class="dg-agent font-medium"><AgentName author={item.author} link={false} /></span>
      {@render counted()}
      <p class="dg-muted text-xs">{item.status_note_words} · {relativeTime(item.created_at)}</p>
    </a>
  </li>
{:else if item.status_note}
  <!-- A status note is one muted line under the agent that sent it, never a card. -->
  <li class="px-4 py-2 text-sm" data-testid="feed-status-note">
    <span class="dg-agent font-medium"><AgentName author={item.author} link={false} /></span>
    <p class="dg-muted text-xs">{item.status_note_words} · {relativeTime(item.created_at)}</p>
  </li>
{:else}
  <li>
    <a class="dg-row" {href} data-testid="feed-row">
      <div class="min-w-0 flex-1">
        <div class="flex flex-wrap items-baseline gap-x-2 text-sm">
          <span class="font-medium {agent ? 'dg-agent' : ''}"
            >{#if item.voice === Voice.Person}{speaker(item.voice, item.author)}{:else}<AgentName
                author={item.author}
                link={false}
              />{/if}</span
          >
          {@render counted()}
          {#if item.kind !== 'summary'}<span class="dg-muted">{item.kind}</span>{/if}
          <span class="dg-muted ml-auto text-xs">{relativeTime(item.created_at)}</span>
        </div>
        <p class="truncate text-sm text-stone-700 dark:text-stone-300 {agent ? 'dg-agent' : ''}" data-voice={agent ? 'agent' : 'person'}>
          {item.preview}
        </p>
      </div>
      {#if item.status !== 'posted'}<StatusBadge status={messageStatus(item.status)} />{/if}
    </a>
    <!-- Outside the row's link: its own links open what the review names, not the note. -->
    <ReviewLine reviewedAt={item.reviewed_at} review={item.review} class="-mt-2 px-4 pb-3" />
  </li>
{/if}
