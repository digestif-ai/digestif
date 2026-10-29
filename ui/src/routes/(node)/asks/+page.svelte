<script lang="ts">
  import Empty from '#lib/components/Empty.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import StatusBadge from '#lib/components/StatusBadge.svelte';
  import { askKind, askStatus, relativeTime } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
</script>

<PageHeader title="Asks" />
<ul class="dg-card dg-rows overflow-hidden" aria-label="Asks">
  {#each data.asks as ask (ask.id)}
    <li>
      <a class="dg-row" href={href.ask(ask.id)} data-testid="ask-row">
        <div class="min-w-0 flex-1">
          <p class="truncate text-sm font-medium">{ask.title}</p>
          <p class="dg-muted text-xs">
            {askKind(ask.kind)}{#if ask.from}&nbsp;· from {ask.from.name}{/if} ·
            {ask.status === 'open' ? 'lapses ' + relativeTime(ask.deadline_at) : relativeTime(ask.created_at)}
          </p>
        </div>
        <StatusBadge status={askStatus(ask.status)} />
      </a>
    </li>
  {:else}
    <Empty text="No asks" />
  {/each}
</ul>
