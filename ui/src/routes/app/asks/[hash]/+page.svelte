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
  const ask = $derived(data.ask);
  const lapsed = $derived(Date.parse(ask.lapses_at) <= Date.now());
  const answered = $derived(ask.options.find((o) => o.id === ask.answered));
  const fallback = $derived(ask.options.find((o) => o.id === ask.on_no_answer));

  let pending = $state<string | undefined>(undefined);
  let failure = $state<string | undefined>(undefined);

  async function handleAnswer(option: string): Promise<void> {
    const phone = data.phone;
    if (pending !== undefined || phone.stage !== 'paired') return;
    pending = option;
    failure = undefined;
    try {
      failure = await decide(phone, ask.hash, option);
      if (failure === undefined) await invalidate('phone:state');
    } finally {
      pending = undefined;
    }
  }
</script>

<PageHeader title={ask.title} crumbs={[{ label: 'Asks', href: href.phone() }]} />
<ErrorBanner errors={failure === undefined ? [] : [{ code: 'relay', message: failure }]} />

<section class="dg-card p-4">
  {#if ask.detail !== ''}<p class="text-sm whitespace-pre-line">{ask.detail}</p>{/if}
  <dl class="mt-3 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
    <dt class="dg-muted">{lapsed ? 'Lapsed' : 'Lapses'}</dt>
    <dd>{relativeTime(ask.lapses_at)}</dd>
    <dt class="dg-muted">If unanswered</dt>
    <dd>{fallback?.label ?? ask.on_no_answer}</dd>
    {#if answered}
      <dt class="dg-muted">Answer</dt>
      <dd data-testid="answer">{answered.label}</dd>
    {/if}
  </dl>
</section>

{#if answered === undefined && !lapsed}
  <div class="mt-4 flex flex-col gap-2">
    {#each ask.options as option (option.id)}
      <Button
        variant={option.recommended ? 'primary' : 'secondary'}
        busy={pending === option.id && 'Sending…'}
        disabled={pending !== undefined}
        onclick={() => void handleAnswer(option.id)}>{option.label}</Button
      >
    {/each}
  </div>
{/if}
