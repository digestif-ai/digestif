<script lang="ts">
  import { onDestroy } from 'svelte';
  import { invalidate } from '$app/navigation';
  import Button from '#lib/components/Button.svelte';
  import Empty from '#lib/components/Empty.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import StatusBadge from '#lib/components/StatusBadge.svelte';
  import { ItemStatus } from '#generated/com-bryzek-digestif-node.ts';
  import { relativeTime } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import { itemStatus } from '#lib/items.ts';
  import { PHONE_UNPAUSE_WORDS, PHONE_UNPAUSING_WORDS, pausedSince, phonePause, UNPAUSE_OPTION, UNPAUSE_WORDS } from '#lib/pause.ts';
  import { itemDone } from '#lib/phone/circle.ts';
  import { decide } from '#lib/phone/phone.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const phone = $derived(data.phone);
  // The Inbox as the laptop's lists it: New first, then Done, newest first in each. Read is the
  // laptop's own, so the phone shows an item New until it is Done.
  const rows = $derived(
    phone.stage === 'paired'
      ? [...phone.items.filter((i) => !itemDone(i)), ...phone.items.filter((i) => itemDone(i))].map((item) => ({
          item,
          status: itemDone(item) ? ItemStatus.Done : ItemStatus.New
        }))
      : []
  );

  const pause = $derived(phone.stage === 'paired' ? phonePause(phone.items) : ({ state: 'none' } as const));

  let copied = $state(false);
  let unpausing = $state(false);
  let failure = $state<string | undefined>(undefined);

  // The Paused choice's Unpause: a pick on the phone's own chain, which the machine acts on when it
  // next reads the relays, exactly as the Paused page's Unpause does there.
  async function handleUnpause(): Promise<void> {
    if (unpausing || phone.stage !== 'paired' || pause.state !== 'open') return;
    unpausing = true;
    failure = undefined;
    try {
      failure = await decide(phone, pause.item, UNPAUSE_OPTION);
      if (failure === undefined) await invalidate('phone:state');
    } finally {
      unpausing = false;
    }
  }

  // While the laptop has not admitted this phone, look again every few seconds.
  const timer = setInterval(() => {
    if (phone.stage === 'pairing') void invalidate('phone:state');
  }, 5000);
  onDestroy(() => clearInterval(timer));

  async function handleCopy(): Promise<void> {
    if (phone.stage !== 'pairing') return;
    try {
      await navigator.clipboard.writeText(phone.keys.code);
      copied = true;
    } catch {
      copied = false;
    }
  }
</script>

{#if phone.stage === 'pairing'}
  <h1 class="mb-3 text-xl font-semibold">Pair this phone</h1>
  <section class="dg-card p-4">
    <p class="dg-label mb-1">Pairing code</p>
    <p class="font-mono text-sm break-all" data-testid="pairing-code">{phone.keys.code}</p>
    <div class="mt-3 flex items-center gap-3">
      <button type="button" class="dg-link min-h-11 text-sm" onclick={handleCopy}>{copied ? 'Copied' : 'Copy'}</button>
      <span class="dg-muted text-sm" role="status">Waiting for your laptop</span>
    </div>
  </section>
  <ol class="dg-muted mt-4 list-decimal space-y-1 pl-5 text-sm">
    <li>On your laptop, open Digestif, then Members, then your own name.</li>
    <li>Choose Add a phone and paste this code.</li>
  </ol>
{:else if phone.stage === 'error'}
  <ErrorBanner errors={[{ code: 'relay', message: phone.message }]} />
{:else if phone.pausedSince !== undefined}
  <!-- The Paused page's words, and Unpause while the node's Paused choice is open: its pick is how a phone acts on the machine. -->
  <div class="mb-3 flex items-center justify-between gap-3">
    <h1 class="text-xl font-semibold">Paused</h1>
    {#if pause.state === 'open'}
      <Button variant="primary" busy={unpausing && 'Unpausing…'} disabled={unpausing} onclick={() => void handleUnpause()}>Unpause</Button>
    {/if}
  </div>
  <ErrorBanner errors={failure === undefined ? [] : [{ code: 'relay', message: failure }]} />
  <p class="text-sm leading-6" data-testid="paused-paragraph">{pausedSince(phone.pausedSince)} {UNPAUSE_WORDS}</p>
  <p class="dg-muted mt-3 text-sm" data-testid="paused-phone-line">
    {pause.state === 'unpausing' ? PHONE_UNPAUSING_WORDS : PHONE_UNPAUSE_WORDS}
  </p>
{:else}
  <h1 class="mb-3 text-xl font-semibold">Inbox</h1>
  <ul class="dg-card dg-rows overflow-hidden" aria-label="Inbox">
    {#each rows as { item, status } (item.hash)}
      <li>
        <a
          class="flex min-h-11 items-start justify-between gap-3 px-4 py-3 text-sm hover:bg-stone-50 dark:hover:bg-stone-800"
          href={href.phoneItem(item.hash)}
          data-testid="item-row"
        >
          <span class="flex flex-col">
            <span class={status === ItemStatus.New ? 'font-medium' : ''}>{item.title}</span>
            <span class="dg-muted">{relativeTime(item.created_at)}</span>
          </span>
          <StatusBadge status={itemStatus(status)} />
        </a>
      </li>
    {:else}
      <li><Empty text="Nothing in your Inbox" /></li>
    {/each}
  </ul>
{/if}
