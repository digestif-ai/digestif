<script lang="ts">
  import { createClient } from '#lib/api/client.ts';
  import Empty from '#lib/components/Empty.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import MoreButton from '#lib/components/MoreButton.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import StatusBadge from '#lib/components/StatusBadge.svelte';
  import { askKind, askStatus, relativeTime } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import { More } from '#lib/more.svelte.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const client = createClient();
  const asks = $derived(
    new More(
      data.asks,
      (a) => a.id,
      (page) => client.asks(undefined, page)
    )
  );
</script>

<PageHeader title="Asks" />
<ul class="dg-card dg-rows overflow-hidden" aria-label="Asks">
  {#each asks.rows as ask (ask.id)}
    <li>
      <a class="dg-row" href={href.askRow(ask)} data-testid="ask-row">
        <div class="min-w-0 flex-1">
          <p class="truncate text-sm font-medium">{ask.title}</p>
          <p class="dg-muted text-xs">
            {askKind(ask.kind)}{#if ask.from}&nbsp;· from {ask.from.name}{/if} ·
            {ask.status === 'open' && ask.deadline_at ? 'lapses ' + relativeTime(ask.deadline_at) : relativeTime(ask.created_at)}
          </p>
        </div>
        <StatusBadge status={askStatus(ask.status)} />
      </a>
    </li>
  {:else}
    <Empty text="No asks" />
  {/each}
</ul>
<ErrorBanner errors={asks.errors} />
<MoreButton list={asks} label="More asks" />
