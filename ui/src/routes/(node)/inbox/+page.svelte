<script lang="ts">
  import { createClient } from '#lib/api/client.ts';
  import Button from '#lib/components/Button.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import ItemTable from '#lib/components/ItemTable.svelte';
  import MoreButton from '#lib/components/MoreButton.svelte';
  import { href } from '#lib/href.ts';
  import { INBOX_PAGE, readInbox } from '#lib/inbox.ts';
  import { INBOX_VIEWS, ITEM_KINDS, isUnread, toggledKind } from '#lib/items.ts';
  import { More } from '#lib/more.svelte.ts';
  import { itemThreads } from '#lib/threads.ts';
  import type { PageData } from './$types';

  // The Inbox (DES-51007, ISS-88476): every item addressed to the member and their drafts, unread first,
  // one Gmail-style row each (DIG-474), bold until read; what they sent joins it once someone answers
  // (ISS-64736), and what they archived leaves it until new activity brings it back. The row opens the
  // item, where everything done to it is done. Items about one message are one thread, shown once as its
  // newest unread item, else its latest; a thread of several opens on all of them (ISS-85464). The
  // Filters menu picks a view (the Inbox, Waiting on you, Waiting on others, Archived) and kinds
  // (DIG-476), which the node applies (ISS-86956); threads are formed from the items that pass, 25 at a
  // time, and More's rows join the threads above.
  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const client = createClient();
  const items = $derived(
    new More(
      data.items,
      (x) => x.id,
      (page) => readInbox(client, { state: data.state, kinds: data.kinds }, page),
      INBOX_PAGE
    )
  );
  const threads = $derived(itemThreads(items.rows));
  const view = $derived({ state: data.state, kinds: data.kinds });
  const stateLinks = $derived(
    INBOX_VIEWS.map((x) => ({
      label: x.label,
      on: data.state === x.state,
      href: href.inbox({ ...view, state: x.state })
    }))
  );
  const kindLinks = $derived(
    ITEM_KINDS.map((k) => ({ label: k, on: data.kinds.includes(k), href: href.inbox({ ...view, kinds: toggledKind(data.kinds, k) }) }))
  );
  const filtered = $derived(data.kinds.length > 0 || data.state !== undefined);
  const viewLabel = $derived(INBOX_VIEWS.find((x) => x.state === data.state)?.label ?? 'Inbox');
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
      <nav aria-label="Filter by view">
        <p class="dg-muted px-4 pt-2 text-xs font-medium">View</p>
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
  label={viewLabel}
  rows={threads.map((th) => ({
    item: th.shown,
    count: th.rows.length,
    unread: th.rows.some(isUnread),
    href: th.rows.length > 1 ? href.itemThread(th.key) : href.item(th.shown.id)
  }))}
  self={data.self}
  empty={data.state === undefined ? 'Nothing in your Inbox' : 'Nothing ' + viewLabel.toLowerCase()}
/>
<ErrorBanner errors={items.errors} />
<MoreButton list={items} label="More items" />
