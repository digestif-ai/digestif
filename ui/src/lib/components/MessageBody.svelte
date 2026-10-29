<script lang="ts">
  import type { Message } from '#generated/com-bryzek-digestif-node.ts';
  import { messageStatus, relativeTime, shortKey } from '../format.ts';
  import { href } from '../href.ts';
  import StatusBadge from './StatusBadge.svelte';

  interface Props {
    message: Message;
  }

  let { message: m }: Props = $props();
</script>

<article class="dg-card p-4">
  <dl class="mb-3 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
    <dt class="dg-muted">Status</dt>
    <dd><StatusBadge status={messageStatus(m.status)} /></dd>
    <dt class="dg-muted">Kind</dt>
    <dd>{m.kind}, written by {m.voice === 'person' ? 'the person' : 'the agent'}</dd>
    <dt class="dg-muted">From</dt>
    <dd><a class="dg-link" href={href.member(m.author.identity)}>{m.author.name}</a></dd>
    {#if m.recipient}
      <dt class="dg-muted">To</dt>
      <dd><a class="dg-link" href={href.member(m.recipient.identity)}>{m.recipient.name}</a></dd>
    {/if}
    <dt class="dg-muted">Written</dt>
    <dd>{relativeTime(m.created_at)}</dd>
    {#if m.reply_to}
      <dt class="dg-muted">In reply to</dt>
      <dd><a class="dg-link font-mono text-xs" href={href.message(m.reply_to)}>{shortKey(m.reply_to)}</a></dd>
    {/if}
    {#if m.refused_rule}
      <dt class="dg-muted">Refused by</dt>
      <dd>{m.refused_rule}</dd>
    {/if}
    <dt class="dg-muted">Hash</dt>
    <dd class="font-mono text-xs break-all">{m.hash}</dd>
  </dl>
  {#if m.text !== undefined}
    <p class="whitespace-pre-wrap" data-testid="message-text">{m.text}</p>
  {:else}
    <p class="dg-muted text-sm">
      {m.status === 'retracted'
        ? 'Retracted. The body was dropped.'
        : m.status === 'refused'
          ? 'Nothing was signed.'
          : 'Sealed to someone else.'}
    </p>
  {/if}
</article>
