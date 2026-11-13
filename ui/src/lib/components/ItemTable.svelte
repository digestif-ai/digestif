<script lang="ts">
  import { ItemStatus, Voice, type ItemSummary } from '#generated/com-bryzek-digestif-node.ts';
  import { agentOwner, mailTime } from '../format.ts';
  import { itemKind, itemSender, itemStatus } from '../items.ts';
  import Empty from './Empty.svelte';
  import StatusBadge from './StatusBadge.svelte';

  // The Inbox's table (DES-51007): one row per item, or per thread of items about one message
  // (ISS-85464), shown as one of its items with how many the thread holds; the row is the link.
  interface Row {
    item: ItemSummary;
    href: string;
    count?: number;
    /** Bold while anything in the row's thread is New, though its latest item is not. */
    unread?: boolean;
  }

  interface Props {
    rows: Row[];
    self: string | undefined;
    empty: string;
    label: string;
  }

  let { rows, self, empty, label }: Props = $props();
</script>

<div class="dg-card overflow-hidden">
  <table class="w-full text-left text-sm" aria-label={label}>
    <thead class="dg-muted text-xs">
      <tr>
        <th scope="col" class="px-3 py-2 font-medium">From</th>
        <th scope="col" class="hidden px-3 py-2 font-medium sm:table-cell">Kind</th>
        <th scope="col" class="px-3 py-2 font-medium">Title</th>
        <th scope="col" class="px-3 py-2 font-medium">Status</th>
        <th scope="col" class="px-3 py-2 font-medium">Time</th>
      </tr>
    </thead>
    <tbody>
      {#each rows as { item, href: link, count = 1, unread } (item.id)}
        <tr class="border-t border-stone-200 hover:bg-stone-50 dark:border-stone-800 dark:hover:bg-stone-900" data-testid="item-row">
          <td class="px-3 py-2 text-xs" data-testid="item-from">
            <a href={link} tabindex="-1" title={item.voice === Voice.Agent ? agentOwner(item.author, self) : undefined}
              >{itemSender(item, self)}</a
            >
          </td>
          <td class="dg-muted hidden w-px px-3 py-2 text-xs whitespace-nowrap sm:table-cell" data-testid="item-kind">
            <a href={link} tabindex="-1">{itemKind(item)}</a>
          </td>
          <td class="px-3 py-2"
            ><a class="block min-h-11 py-1 {(unread ?? item.status === ItemStatus.New) ? 'font-medium' : ''}" href={link}
              >{item.title}{#if count > 1}<span
                  class="dg-muted ml-2 text-xs font-normal"
                  data-testid="thread-count"
                  aria-label="{count} items">{count}</span
                >{/if}</a
            ></td
          >
          <td class="w-px px-3 py-2 whitespace-nowrap"><a href={link} tabindex="-1"><StatusBadge status={itemStatus(item.status)} /></a></td
          >
          <td class="dg-muted w-px px-3 py-2 text-xs whitespace-nowrap" data-testid="item-time">
            <a href={link} tabindex="-1">{mailTime(item.created_at)}</a>
          </td>
        </tr>
      {:else}
        <tr><td colspan="5"><Empty text={empty} /></td></tr>
      {/each}
    </tbody>
  </table>
</div>
