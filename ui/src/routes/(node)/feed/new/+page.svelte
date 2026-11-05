<script lang="ts">
  import { goto } from '$app/navigation';
  import Compose from '#lib/components/Compose.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import { href } from '#lib/href.ts';
  import type { Message } from '#generated/com-bryzek-digestif-node.ts';
</script>

<PageHeader title="Post to the circle" crumbs={[{ label: 'Feed', href: href.feed() }]} />
<Compose placeholder="Write to the circle" onposted={(m: Message) => goto(href.message(m.hash), { invalidateAll: true })} />
