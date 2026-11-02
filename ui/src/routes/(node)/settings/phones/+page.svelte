<script lang="ts">
  import Button from '#lib/components/Button.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import StatusBadge from '#lib/components/StatusBadge.svelte';
  import { relativeTime, shortKey } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
</script>

<PageHeader title="Phones" crumbs={[{ label: 'Settings', href: href.settings() }]}>
  {#snippet actions()}
    <Button href={href.phoneNew()}>Add a phone</Button>
  {/snippet}
</PageHeader>

<ul class="dg-card dg-rows overflow-hidden" aria-label="Phones">
  {#each data.phones as phone (phone.key)}
    <li class="flex min-h-11 items-center gap-3 px-4 py-3 text-sm" data-testid="phone-row">
      <span class="font-mono text-xs">{shortKey(phone.key)}</span>
      <span class="dg-muted">added {relativeTime(phone.admitted_at)}</span>
      {#if phone.revoked_at}<span class="ml-auto"><StatusBadge status={{ label: 'Revoked', tone: 'bad' }} /></span>{/if}
    </li>
  {:else}
    <li class="dg-muted px-4 py-6 text-center text-sm">No phones</li>
  {/each}
</ul>
