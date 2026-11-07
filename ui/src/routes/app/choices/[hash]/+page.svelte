<script lang="ts">
  import { invalidate } from '$app/navigation';
  import Button from '#lib/components/Button.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import { relativeTime } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import { decide } from '#lib/phone/phone.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const choice = $derived(data.choice);
  const passed = $derived(choice.deadline !== undefined && Date.parse(choice.deadline) <= Date.now());
  const picked = $derived(choice.options.find((o) => o.id === choice.picked));
  const fallback = $derived(choice.options.find((o) => o.id === choice.default));

  let pending = $state<string | undefined>(undefined);
  let failure = $state<string | undefined>(undefined);

  async function handlePick(option: string): Promise<void> {
    const phone = data.phone;
    if (pending !== undefined || phone.stage !== 'paired') return;
    pending = option;
    failure = undefined;
    try {
      failure = await decide(phone, choice.hash, option);
      if (failure === undefined) await invalidate('phone:state');
    } finally {
      pending = undefined;
    }
  }
</script>

<PageHeader title={choice.title} crumbs={[{ label: 'Choices', href: href.phone() }]} />
<ErrorBanner errors={failure === undefined ? [] : [{ code: 'relay', message: failure }]} />

<section class="dg-card p-4">
  {#if choice.detail !== ''}<p class="text-sm whitespace-pre-line">{choice.detail}</p>{/if}
  <dl class="mt-3 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
    {#if choice.deadline !== undefined}
      <dt class="dg-muted">{passed ? 'Closed' : 'Closes'}</dt>
      <dd>{relativeTime(choice.deadline)}</dd>
    {/if}
    <dt class="dg-muted">With no pick</dt>
    <dd>{fallback?.label ?? choice.default}</dd>
    {#if picked}
      <dt class="dg-muted">Picked</dt>
      <dd data-testid="picked">{picked.label}</dd>
    {/if}
  </dl>
</section>

{#if picked === undefined && !passed}
  <div class="mt-4 flex flex-col gap-2">
    {#each choice.options as option (option.id)}
      <Button
        variant={option.recommended ? 'primary' : 'secondary'}
        busy={pending === option.id && 'Sending…'}
        disabled={pending !== undefined}
        onclick={() => void handlePick(option.id)}>{option.label}</Button
      >
    {/each}
  </div>
{/if}
