<script lang="ts">
  import PageHeader from '#lib/components/PageHeader.svelte';
  import StatusBadge from '#lib/components/StatusBadge.svelte';
  import { guestStatus, relativeTime } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const dinner = $derived(data.dinner);
</script>

<PageHeader title={dinner.label} crumbs={[{ label: 'Dinners', href: href.dinners() }]} />

<section class="dg-card p-4">
  <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
    <dt class="dg-muted">Date</dt>
    <dd>{dinner.date}</dd>
    <dt class="dg-muted">Host</dt>
    <dd><a class="dg-link" href={href.member(dinner.host.identity)}>{dinner.host.name}</a></dd>
    <dt class="dg-muted">Relays</dt>
    <dd>
      {#each dinner.relays as relay (relay)}<span class="block break-all">{relay}</span>{/each}
    </dd>
  </dl>
</section>

<h2 class="dg-label mt-6 mb-2">Guests</h2>
<ul class="dg-card dg-rows overflow-hidden" aria-label="Guests">
  {#each dinner.guests as guest (guest.name)}
    <li>
      {#if guest.identity}
        <a class="dg-row" href={href.member(guest.identity)}>
          <span class="min-w-0 flex-1 truncate text-sm">{guest.name}</span>
          <StatusBadge status={guestStatus(guest.status)} />
        </a>
      {:else}
        <div class="flex min-h-11 items-center gap-3 px-4 py-3">
          <div class="min-w-0 flex-1">
            <p class="truncate text-sm">{guest.name}</p>
            {#if guest.status === 'invited'}<p class="dg-muted text-xs">invite expires {relativeTime(guest.expires_at)}</p>{/if}
          </div>
          <StatusBadge status={guestStatus(guest.status)} />
        </div>
      {/if}
    </li>
  {/each}
</ul>
