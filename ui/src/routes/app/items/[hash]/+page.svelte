<script lang="ts">
  import { invalidate } from '$app/navigation';
  import { ItemStatus } from '#generated/com-bryzek-digestif-node.ts';
  import Button from '#lib/components/Button.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import StatusBadge from '#lib/components/StatusBadge.svelte';
  import { relativeTime } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import { itemStatus } from '#lib/items.ts';
  import { ACKNOWLEDGE, itemDone } from '#lib/phone/circle.ts';
  import { decide } from '#lib/phone/phone.ts';
  import type { PageData } from './$types';

  // One item on the phone (docs/protocol.md, Items): a choice is picked, a notice acknowledged, each
  // as a decision on the phone's own chain that the member's node reads when it next syncs.
  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const item = $derived(data.item);
  const done = $derived(itemDone(item));
  const lapsed = $derived(item.deadline !== undefined && Date.parse(item.deadline) <= Date.now());
  const label = (id: string | undefined): string | undefined => item.options.find((o) => o.id === id)?.label ?? id;
  const options = $derived([...item.options].sort((a, b) => Number(b.recommended) - Number(a.recommended)));

  let pending = $state<string | undefined>(undefined);
  let failure = $state<string | undefined>(undefined);

  async function handleAnswer(option: string): Promise<void> {
    const phone = data.phone;
    if (pending !== undefined || phone.stage !== 'paired') return;
    pending = option;
    failure = undefined;
    try {
      failure = await decide(phone, item, option);
      if (failure === undefined) await invalidate('phone:state');
    } finally {
      pending = undefined;
    }
  }
</script>

<PageHeader title={item.title} crumbs={[{ label: 'Inbox', href: href.phone() }]} />

<p class="dg-muted -mt-2 mb-4 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs" data-testid="item-subline">
  <StatusBadge status={itemStatus(done ? ItemStatus.Done : ItemStatus.New)} />
  <span>{item.kind === 'choice' ? 'Choice' : 'Notice'}</span>
  <span>{relativeTime(item.created_at)}</span>
</p>

<ErrorBanner errors={failure === undefined ? [] : [{ code: 'relay', message: failure }]} />

<section class="dg-card p-4">
  {#if item.detail !== ''}<p class="text-sm whitespace-pre-line" data-testid="item-detail">{item.detail}</p>{/if}
  <dl class="mt-3 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
    {#if item.kind === 'choice'}
      {#if item.deadline !== undefined}
        <dt class="dg-muted">{lapsed ? 'Deadline passed' : 'Deadline'}</dt>
        <dd>{relativeTime(item.deadline)}</dd>
      {/if}
      <dt class="dg-muted">If nobody picks</dt>
      <dd>{label(item.default)}</dd>
    {/if}
    {#if item.picked !== undefined}
      <dt class="dg-muted">{item.kind === 'choice' ? 'Your pick' : 'You'}</dt>
      <dd data-testid="answer">{item.kind === 'choice' ? label(item.picked) : 'Acknowledged'}</dd>
    {:else if item.closed}
      <dt class="dg-muted">Closed</dt>
      <dd>by its author</dd>
    {/if}
  </dl>
</section>

{#if !done}
  <div class="mt-4 flex flex-col gap-2">
    {#if item.kind === 'choice'}
      {#each options as option (option.id)}
        <Button
          variant={option.recommended ? 'primary' : 'secondary'}
          busy={pending === option.id && 'Sending…'}
          disabled={pending !== undefined}
          onclick={() => void handleAnswer(option.id)}>{option.label}</Button
        >
      {/each}
    {:else}
      <Button
        variant="primary"
        busy={pending === ACKNOWLEDGE && 'Sending…'}
        disabled={pending !== undefined}
        onclick={() => void handleAnswer(ACKNOWLEDGE)}>Acknowledge</Button
      >
    {/if}
  </div>
{/if}
