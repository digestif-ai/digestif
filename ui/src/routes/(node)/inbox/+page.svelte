<script lang="ts">
  import { ItemState, ItemStatus } from '#generated/ai-digestif-digestif-node.ts';
  import { createClient } from '#lib/api/client.ts';
  import Button from '#lib/components/Button.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import ItemTable from '#lib/components/ItemTable.svelte';
  import MoreButton from '#lib/components/MoreButton.svelte';
  import { href } from '#lib/href.ts';
  import { INBOX_PAGE, readInbox } from '#lib/inbox.ts';
  import { ITEM_KINDS, ITEM_STATES, toggledKind, toggledState } from '#lib/items.ts';
  import { More } from '#lib/more.svelte.ts';
  import { itemThreads } from '#lib/threads.ts';
  import type { PageData } from './$types';

  // The Inbox (DES-51007): every item addressed to the member, their drafts, and what they sent,
  // Waiting on others until someone acts on it (ISS-64736, ISS-86956), Draft and New first, one Gmail-style row each (DIG-474); the row
  // opens the item, where everything done to it is done. Items about one message are one thread,
  // shown once as its newest item still waiting on the member, else its latest; a thread of several
  // opens on all of them (ISS-85464). The Filters menu picks states and kinds (DIG-476), which the node
  // applies (ISS-86956); threads are formed from the items that pass, 25 at a time, and More's rows join
  // the threads above.
  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const client = createClient();
  const items = $derived(
    new More(
      data.items,
      (x) => x.id,
      (page) => readInbox(client, { states: data.states, kinds: data.kinds }, page),
      INBOX_PAGE
    )
  );
  const threads = $derived(itemThreads(items.rows));
  const view = $derived({ states: data.states, kinds: data.kinds });
  const stateLinks = $derived(
    ITEM_STATES.map((x) => ({
      label: x.label,
      on: data.states.includes(x.state),
      href: href.inbox({ ...view, states: toggledState(data.states, x.state) })
    }))
  );
  const kindLinks = $derived(
    ITEM_KINDS.map((k) => ({ label: k, on: data.kinds.includes(k), href: href.inbox({ ...view, kinds: toggledKind(data.kinds, k) }) }))
  );
  const filtered = $derived(data.kinds.length > 0 || data.states.length !== 2 || data.states.includes(ItemState.Done));
</script>

{#snippet check(link: { label: string; on: boolean; href: string })}
  <a
    href={link.href}
    aria-current={link.on ? 'true' : undefined}
    class="flex min-h-11 items-center px-4 text-sm hover:bg-stone-50 dark:hover:bg-stone-800 {link.on ? 'font-medium' : ''}"
    ><span aria-hidden="true" class="mr-2 inline-block w-4">{link.on ? '✓' : ''}</span>{#if link.on}<span class="sr-only"
        >Showing
      </span>{/if}{link.label}</a
  >
{/snippet}

<div class="mb-3 flex items-center justify-between gap-3">
  <details class="relative">
    <summary
      class="inline-flex min-h-11 cursor-pointer list-none items-center rounded-md border border-stone-300 bg-white px-3 text-sm dark:border-stone-700 dark:bg-stone-900"
      >Filters{filtered ? ' (on)' : ''}</summary
    >
    <div class="dg-card absolute left-0 z-10 mt-1 w-64 max-w-[calc(100vw-2rem)] overflow-hidden shadow-lg">
      <nav aria-label="Filter by state">
        <p class="dg-muted px-4 pt-2 text-xs font-medium">State</p>
        {#each stateLinks as link (link.label)}{@render check(link)}{/each}
      </nav>
      <nav aria-label="Filter by kind" class="border-t border-stone-200 dark:border-stone-800">
        <p class="dg-muted px-4 pt-2 text-xs font-medium">Kind</p>
        {#each kindLinks as link (link.label)}{@render check(link)}{/each}
      </nav>
    </div>
  </details>
  <Button variant="primary" href={href.newItem()}>New item</Button>
</div>

<ItemTable
  label="Inbox"
  rows={threads.map((th) => ({
    item: th.shown,
    count: th.rows.length,
    unread: th.rows.some((i) => i.status === ItemStatus.New),
    href: th.rows.length > 1 ? href.itemThread(th.key) : href.item(th.shown.id)
  }))}
  self={data.self}
  empty={data.states.length === 0 ? 'No state checked' : 'Nothing in your Inbox'}
/>
<ErrorBanner errors={items.errors} />
<MoreButton list={items} label="More items" />
