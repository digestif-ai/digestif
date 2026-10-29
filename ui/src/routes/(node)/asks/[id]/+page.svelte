<script lang="ts">
  import { refreshAll } from '$app/navigation';
  import { createClient } from '#lib/api/client.ts';
  import Button from '#lib/components/Button.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import StatusBadge from '#lib/components/StatusBadge.svelte';
  import { askKind, askStatus, relativeTime } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import { Submission } from '#lib/submission.svelte.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const ask = $derived(data.ask);
  const options = $derived([...ask.options].sort((a, b) => Number(b.recommended) - Number(a.recommended)));
  const chosen = $derived(ask.answer === undefined ? undefined : ask.options.find((o) => o.id === ask.answer?.option_id));

  const client = createClient();
  const submission = new Submission();

  async function handleAnswer(optionId: string): Promise<void> {
    await submission.run(
      () => client.answer(ask.id, optionId),
      () => refreshAll(),
      optionId
    );
  }
</script>

<PageHeader title={ask.title} crumbs={[{ label: 'Asks', href: href.asks() }]} />

<article class="dg-card p-4">
  <dl class="mb-3 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
    <dt class="dg-muted">Status</dt>
    <dd><StatusBadge status={askStatus(ask.status)} /></dd>
    <dt class="dg-muted">Kind</dt>
    <dd>{askKind(ask.kind)}</dd>
    {#if ask.from}
      <dt class="dg-muted">From</dt>
      <dd><a class="dg-link" href={href.member(ask.from.identity)}>{ask.from.name}</a></dd>
    {/if}
    <dt class="dg-muted">Deadline</dt>
    <dd>{relativeTime(ask.deadline_at)}</dd>
    <dt class="dg-muted">No answer</dt>
    <dd>{ask.on_no_answer}</dd>
    {#if ask.message}
      <dt class="dg-muted">Raised by</dt>
      <dd><a class="dg-link" href={href.message(ask.message)}>the message</a></dd>
    {/if}
  </dl>
  <p class="whitespace-pre-wrap">{ask.detail}</p>
</article>

{#if ask.status === 'open'}
  <div class="mt-4">
    <ErrorBanner errors={submission.errors} />
    <div class="flex flex-wrap gap-2">
      {#each options as option (option.id)}
        <Button
          variant={option.recommended ? 'primary' : 'secondary'}
          busy={submission.pending(option.id) && 'Answering…'}
          disabled={submission.busy()}
          onclick={() => handleAnswer(option.id)}>{option.label}{option.recommended ? ' (recommended)' : ''}</Button
        >
      {/each}
    </div>
  </div>
{:else if chosen && ask.answer}
  <p class="mt-4 text-sm" data-testid="ask-answer">You answered <strong>{chosen.label}</strong> {relativeTime(ask.answer.answered_at)}.</p>
{/if}
