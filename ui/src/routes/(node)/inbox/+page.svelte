<script lang="ts">
  import { createClient } from '#lib/api/client.ts';
  import Button from '#lib/components/Button.svelte';
  import Empty from '#lib/components/Empty.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import MoreButton from '#lib/components/MoreButton.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import StatusBadge from '#lib/components/StatusBadge.svelte';
  import { Voice } from '#generated/com-bryzek-digestif-node.ts';
  import { agentOwner, relativeTime } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import { DEFAULT_STATUSES, ITEM_STATUSES, itemSender, itemStatus, toggled } from '#lib/items.ts';
  import { More } from '#lib/more.svelte.ts';
  import type { PageData } from './$types';

  // The Inbox (DES-51007): every item addressed to the member, their drafts, and what they sent once
  // someone acts on it (ISS-64736), Draft and New first, one row each; the row opens the item, where
  // everything done to it is done.
  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const client = createClient();
  const items = $derived(
    new More(
      data.items,
      (x) => x.id,
      (page) => client.items(data.checked, page)
    )
  );
  // One check per status, Draft, New and Read checked by default (ISS-71225); each toggles its own.
  const filters = $derived(
    ITEM_STATUSES.map((s) => {
      const next = toggled(data.checked, s);
      const isDefault = next.length === DEFAULT_STATUSES.length && next.every((x) => DEFAULT_STATUSES.includes(x));
      return { label: itemStatus(s).label, href: isDefault ? href.inbox() : href.inbox(next), on: data.checked.includes(s) };
    })
  );
</script>

<PageHeader title="Inbox">
  {#snippet actions()}
    <Button variant="primary" href={href.newItem()}>New item</Button>
  {/snippet}
</PageHeader>

<nav aria-label="Filter by status" class="mb-3">
  <ul class="flex flex-wrap gap-2">
    {#each filters as f (f.href)}
      <li>
        <a
          href={f.href}
          aria-current={f.on ? 'true' : undefined}
          class="inline-flex min-h-9 items-center rounded-full border px-3 text-xs {f.on
            ? 'border-dg-accent font-medium text-dg-accent dark:text-pink-300'
            : 'border-stone-300 bg-white dark:border-stone-700 dark:bg-stone-900'}"
          >{#if f.on}<span aria-hidden="true" class="mr-1">✓</span><span class="sr-only">Showing </span>{/if}{f.label}</a
        >
      </li>
    {/each}
  </ul>
</nav>

<div class="dg-card overflow-hidden">
  <table class="w-full text-left text-sm" aria-label="Inbox">
    <thead class="dg-muted text-xs">
      <tr>
        <th scope="col" class="px-3 py-2 font-medium">Title</th>
        <th scope="col" class="px-3 py-2 font-medium">From</th>
        <th scope="col" class="px-3 py-2 font-medium">Status</th>
        <th scope="col" class="hidden px-3 py-2 font-medium sm:table-cell">Reviewed</th>
        <th scope="col" class="hidden px-3 py-2 font-medium sm:table-cell">Created</th>
      </tr>
    </thead>
    <tbody>
      {#each items.rows as item (item.id)}
        {@const link = href.item(item.id)}
        <tr class="border-t border-stone-200 hover:bg-stone-50 dark:border-stone-800 dark:hover:bg-stone-900" data-testid="item-row">
          <td class="px-3 py-2"><a class="block min-h-11 py-1 {item.status === 'new' ? 'font-medium' : ''}" href={link}>{item.title}</a></td
          >
          <td class="px-3 py-2 text-xs" data-testid="item-from">
            <a href={link} tabindex="-1" title={item.voice === Voice.Agent ? agentOwner(item.author, data.self) : undefined}
              >{itemSender(item, data.self)}</a
            >
          </td>
          <td class="w-px px-3 py-2 whitespace-nowrap"><a href={link} tabindex="-1"><StatusBadge status={itemStatus(item.status)} /></a></td
          >
          <td class="dg-muted hidden w-px px-3 py-2 text-xs whitespace-nowrap sm:table-cell">
            <a href={link} tabindex="-1">{item.reviewed_at === undefined ? '—' : relativeTime(item.reviewed_at)}</a>
          </td>
          <td class="dg-muted hidden w-px px-3 py-2 text-xs whitespace-nowrap sm:table-cell">
            <a href={link} tabindex="-1">{relativeTime(item.created_at)}</a>
          </td>
        </tr>
      {:else}
        <tr><td colspan="5"><Empty text={data.checked.length === 0 ? 'No status checked' : 'Nothing in your Inbox'} /></td></tr>
      {/each}
    </tbody>
  </table>
</div>
<ErrorBanner errors={items.errors} />
<MoreButton list={items} label="More items" />
