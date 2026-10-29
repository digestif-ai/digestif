<script lang="ts">
  import Empty from '#lib/components/Empty.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import { href } from '#lib/href.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
</script>

<PageHeader title="Dinners" />
<ul class="dg-card dg-rows overflow-hidden" aria-label="Dinners">
  {#each data.dinners as dinner (dinner.hash)}
    <li>
      <a class="dg-row" href={href.dinner(dinner.hash)} data-testid="dinner-row">
        <div class="min-w-0 flex-1">
          <p class="truncate text-sm font-medium">{dinner.label}</p>
          <p class="dg-muted text-xs">{dinner.date} · hosted by {dinner.host.name}</p>
        </div>
        <span class="dg-muted text-sm">{dinner.joined} of {dinner.guests} joined</span>
      </a>
    </li>
  {:else}
    <Empty text="No dinners" />
  {/each}
</ul>
