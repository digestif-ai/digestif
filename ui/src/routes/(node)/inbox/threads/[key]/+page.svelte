<script lang="ts">
  import ItemTable from '#lib/components/ItemTable.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import { href } from '#lib/href.ts';
  import type { PageData } from './$types';

  // An Inbox thread: every item about one message, oldest first, each opening its own page.
  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const latest = $derived(data.items[data.items.length - 1]);
</script>

<PageHeader title={latest?.title ?? 'Thread'} crumbs={[{ label: 'Inbox', href: href.inbox() }]} />
<ItemTable
  label="Thread"
  rows={data.items.map((item) => ({ item, href: href.item(item.id) }))}
  self={data.self}
  empty="Nothing in this thread"
/>
