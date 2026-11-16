<script lang="ts">
  import { Voice, type ItemSummary } from '#generated/ai-digestif-digestif-node.ts';
  import { agentOwner, mailTime } from '../format.ts';
  import { isUnread, itemKind, itemSender, waitingText } from '../items.ts';
  import Empty from './Empty.svelte';
  import ReviewText from './ReviewText.svelte';

  // The Inbox's table (DES-51007): one row per item, or per thread of items about one message
  // (ISS-85464), shown as one of its items with how many the thread holds; the row is the link. An
  // unread row is bold with a dot, a read one plain and muted, the way a mail client shows it, and
  // Waiting on names whom an item waits on, blank when it asks nothing (ISS-88476). Work its agent
  // filed shows where under its title, as a link of its own (DIG-124).
  interface Row {
    item: ItemSummary;
    href: string;
    count?: number;
    /** Bold while anything in the row's thread is unread, though its latest item is not. */
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
        <th scope="col" class="hidden px-3 py-2 font-medium sm:table-cell">Waiting on</th>
        <th scope="col" class="px-3 py-2 font-medium">Time</th>
      </tr>
    </thead>
    <tbody>
      {#each rows as { item, href: link, count = 1, unread } (item.id)}
        {@const bold = unread ?? isUnread(item)}
        <tr
          class="border-t border-stone-200 hover:bg-stone-50 dark:border-stone-800 dark:hover:bg-stone-900 {bold
            ? 'font-semibold text-stone-900 dark:text-stone-50'
            : 'text-stone-500 dark:text-stone-400'}"
          data-testid="item-row"
          data-unread={bold ? 'true' : undefined}
        >
          <td class="px-3 py-2 text-xs" data-testid="item-from">
            <a
              href={link}
              tabindex="-1"
              class="flex items-center gap-2"
              title={item.voice === Voice.Agent ? agentOwner(item.author, self) : undefined}
              ><span
                aria-hidden="true"
                class="inline-block size-2 shrink-0 rounded-full {bold ? 'bg-dg-accent dark:bg-pink-300' : 'bg-transparent'}"
              ></span>{itemSender(item, self)}</a
            >
          </td>
          <td class="dg-muted hidden w-px px-3 py-2 text-xs whitespace-nowrap sm:table-cell" data-testid="item-kind">
            <a href={link} tabindex="-1">{itemKind(item)}</a>
          </td>
          <td class="px-3 py-2"
            ><a class="block min-h-11 py-1" href={link}
              >{#if bold}<span class="sr-only">Unread: </span>{/if}{item.title}{#if count > 1}<span
                  class="dg-muted ml-2 text-xs font-normal"
                  data-testid="thread-count"
                  aria-label="{count} items">{count}</span
                >{/if}</a
            >{#if item.link}<p class="dg-muted -mt-1 pb-1 text-xs font-normal" data-testid="item-link">
                <ReviewText review={item.link} />
              </p>{/if}</td
          >
          <td class="hidden w-px px-3 py-2 text-xs whitespace-nowrap sm:table-cell" data-testid="item-waiting">
            <a href={link} tabindex="-1">{waitingText(item)}</a>
          </td>
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
