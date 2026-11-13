<script lang="ts">
  import { ItemStatus } from '#generated/com-bryzek-digestif-node.ts';
  import { createClient } from '#lib/api/client.ts';
  import Button from '#lib/components/Button.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import ItemTable from '#lib/components/ItemTable.svelte';
  import MoreButton from '#lib/components/MoreButton.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import { href } from '#lib/href.ts';
  import { DEFAULT_STATUSES, ITEM_STATUSES, itemStatus, toggled } from '#lib/items.ts';
  import { More } from '#lib/more.svelte.ts';
  import { itemThreads } from '#lib/threads.ts';
  import type { PageData } from './$types';

  // The Inbox (DES-51007): every item addressed to the member, their drafts, and what they sent once
  // someone acts on it (ISS-64736), Draft and New first, one row each; the row opens the item, where
  // everything done to it is done. Items about one message are one thread, shown once as its
  // newest item still waiting on the member, else its latest; a thread of several opens on all of them (ISS-85464). More's rows join the threads above.
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
  const threads = $derived(itemThreads(items.rows));
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

<ItemTable
  label="Inbox"
  rows={threads.map((th) => ({
    item: th.shown,
    count: th.rows.length,
    unread: th.rows.some((i) => i.status === ItemStatus.New),
    href: th.rows.length > 1 ? href.itemThread(th.key) : href.item(th.shown.id)
  }))}
  self={data.self}
  empty={data.checked.length === 0 ? 'No status checked' : 'Nothing in your Inbox'}
/>
<ErrorBanner errors={items.errors} />
<MoreButton list={items} label="More items" />
