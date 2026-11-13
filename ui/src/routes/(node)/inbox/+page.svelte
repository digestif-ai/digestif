<script lang="ts">
  import Button from '#lib/components/Button.svelte';
  import Empty from '#lib/components/Empty.svelte';
  import StatusBadge from '#lib/components/StatusBadge.svelte';
  import { mailTime } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import { ITEM_KINDS, ITEM_STATES, itemKind, itemSender, itemStatus, toggledKind, toggledState } from '#lib/items.ts';
  import { ItemStatus } from '#generated/com-bryzek-digestif-node.ts';
  import type { PageData } from './$types';

  // The Inbox (DES-51007): every item addressed to the member, their drafts, and what they sent once
  // someone acts on it (ISS-64736), Draft and New first, one Gmail-style row each (DIG-474); the row
  // opens the item, where everything done to it is done. The filter menu picks states and kinds (DIG-476).
  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const view = $derived({ states: data.states, kinds: data.kinds });
  // A filter change starts again at the newest page.
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
  const lastId = $derived(data.rows[data.rows.length - 1]?.id);
  const older = $derived(data.more && lastId !== undefined ? href.inbox({ ...view, after: [...data.after, lastId] }) : undefined);
  const newer = $derived(data.after.length === 0 ? undefined : href.inbox({ ...view, after: data.after.slice(0, -1) }));
  const filtered = $derived(data.kinds.length > 0 || data.states.length !== 2 || data.states.includes('done'));
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

<div class="dg-card overflow-hidden">
  <ul aria-label="Inbox" class="text-sm">
    {#each data.rows as item (item.id)}
      <li class="border-t border-stone-200 first:border-t-0 dark:border-stone-800" data-testid="item-row">
        <a
          class="grid min-h-11 grid-cols-[1fr_auto] items-baseline gap-x-3 px-3 py-2 hover:bg-stone-50 sm:grid-cols-[11rem_1fr_auto] dark:hover:bg-stone-900 {item.status ===
          ItemStatus.New
            ? 'font-medium'
            : ''}"
          href={href.item(item.id)}
        >
          <span class="truncate" data-testid="item-from">{itemSender(item, data.self)}</span>
          <span class="dg-muted col-start-2 row-start-1 text-xs whitespace-nowrap sm:col-start-3" data-testid="item-time"
            >{mailTime(item.created_at)}</span
          >
          <span class="col-span-2 flex min-w-0 items-baseline gap-2 sm:col-span-1 sm:col-start-2 sm:row-start-1">
            {#if item.status === ItemStatus.Draft || item.status === ItemStatus.Done}
              <StatusBadge status={itemStatus(item.status)} />
            {/if}
            <span class="dg-muted shrink-0 text-xs font-normal" data-testid="item-kind">{itemKind(item)}</span>
            <span class="truncate">{item.title}</span>
          </span>
        </a>
      </li>
    {:else}
      <li><Empty text={data.states.length === 0 ? 'No state checked' : 'Nothing in your Inbox'} /></li>
    {/each}
  </ul>
</div>
{#if newer !== undefined || older !== undefined}
  <nav aria-label="Pages" class="mt-3 flex justify-between text-sm">
    {#if newer !== undefined}<a class="dg-link inline-flex min-h-11 items-center" href={newer}>Newer</a>{:else}<span></span>{/if}
    {#if older !== undefined}<a class="dg-link inline-flex min-h-11 items-center" href={older}>Older</a>{/if}
  </nav>
{/if}
