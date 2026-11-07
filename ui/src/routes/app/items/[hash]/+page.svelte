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
  import { ACKNOWLEDGE, itemClosed, itemDone, type PhoneAnswer } from '#lib/phone/circle.ts';
  import { answer as writeAnswer, CIRCLE_ANSWER_ON_MACHINE, decide } from '#lib/phone/phone.ts';
  import type { PageData } from './$types';

  // One item on the phone (docs/protocol.md, Items): a question is answered, a choice picked, a
  // notice acknowledged, each written on the phone's own chain, and the member's node reads it when
  // it next syncs.
  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const item = $derived(data.item);
  const done = $derived(itemDone(item));
  const closed = $derived(itemClosed(item));
  const self = $derived(data.phone.stage === 'paired' ? data.phone.enrollment.identity : undefined);
  const kindLabel = { question: 'Question', choice: 'Choice', notice: 'Notice' } as const;
  /** "You", "Ada Park", "Juno (Ada Park's agent)". */
  const answerer = (a: PhoneAnswer): string => {
    const name = a.author === self ? 'You' : (a.name ?? 'A member');
    if (a.voice === 'person') return name;
    return (a.agentName ?? 'Their agent') + ' (' + (a.author === self ? 'your' : name + "'s") + ' agent)';
  };
  const lapsed = $derived(item.deadline !== undefined && Date.parse(item.deadline) <= Date.now());
  const label = (id: string | undefined): string | undefined => item.options.find((o) => o.id === id)?.label ?? id;
  const options = $derived([...item.options].sort((a, b) => Number(b.recommended) - Number(a.recommended)));

  let pending = $state<string | undefined>(undefined);
  let failure = $state<string | undefined>(undefined);
  let words = $state('');

  async function handleSubmitAnswer(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    const phone = data.phone;
    if (pending !== undefined || phone.stage !== 'paired') return;
    pending = 'answer';
    failure = undefined;
    try {
      failure = await writeAnswer(phone, item, words);
      if (failure === undefined) {
        words = '';
        await invalidate('phone:state');
      }
    } finally {
      pending = undefined;
    }
  }

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
  <span>{kindLabel[item.kind]}</span>
  {#if item.author !== self}<span>from {item.authorName ?? 'a member'}</span>{/if}
  {#if item.to === 'circle'}<span>to the circle</span>{/if}
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
    {:else if item.kind === 'question' && closed}
      <dt class="dg-muted">Closed</dt>
      <dd>{item.closed ? 'by its author' : 'with no answer after a week'}</dd>
    {:else if item.closed}
      <dt class="dg-muted">Closed</dt>
      <dd>by its author</dd>
    {/if}
  </dl>
</section>

{#if item.kind === 'question'}
  <h2 class="dg-label mt-6 mb-2">Answers · {item.answers.length}</h2>
  <ul class="dg-card dg-rows" aria-label="Answers">
    {#each item.answers as a (a.hash)}
      <li class="px-4 py-3" data-testid="item-answer">
        <p class="dg-muted mb-1 flex flex-wrap items-center gap-2 text-xs">
          <span class="font-medium text-stone-900 dark:text-stone-100">{answerer(a)}</span>
          <span>{relativeTime(a.created_at)}</span>
        </p>
        <p class="text-sm whitespace-pre-wrap">{a.text}</p>
      </li>
    {:else}
      <li class="dg-muted px-4 py-6 text-center text-sm">No answers yet</li>
    {/each}
  </ul>
  {#if !closed && item.to === 'circle'}
    <p class="dg-muted mt-4 text-sm" data-testid="circle-answer-line">{CIRCLE_ANSWER_ON_MACHINE}</p>
  {:else if !closed}
    <form class="mt-6" aria-label="Answer the question" onsubmit={handleSubmitAnswer}>
      <label class="dg-label mb-2 block" for="item-answer">Your answer</label>
      <div class="dg-card p-4">
        <textarea id="item-answer" class="dg-input min-h-24" bind:value={words} disabled={pending !== undefined}></textarea>
        <div class="mt-3 flex justify-end">
          <Button variant="primary" type="submit" busy={pending === 'answer' && 'Answering…'} disabled={pending !== undefined}
            >Answer</Button
          >
        </div>
      </div>
    </form>
  {/if}
{:else if !done}
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
