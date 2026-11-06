<script lang="ts">
  import { goto } from '$app/navigation';
  import { createClient } from '#lib/api/client.ts';
  import Button from '#lib/components/Button.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import StatusBadge from '#lib/components/StatusBadge.svelte';
  import { promptPick, relativeTime, roundResult, suggestionStatus } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import { Submission } from '#lib/submission.svelte.ts';
  import type { PageData } from './$types';

  // One suggestion: its judges, every round's picks and the whole prompt. Withdraw is a mode of this
  // page, the author's while it is judging.
  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const s = $derived(data.suggestion);
  const client = createClient();
  const submission = new Submission();
  let confirming = $state(false);

  async function handleWithdraw(): Promise<void> {
    await submission.run(
      () => client.withdrawPromptSuggestion(s.hash),
      () => goto(href.notePrompt(), { refreshAll: true })
    );
  }
</script>

<PageHeader
  title={s.change || 'Withdrawn suggestion'}
  crumbs={[
    { label: 'Settings', href: href.settings() },
    { label: 'Note prompt', href: href.notePrompt() }
  ]}
/>
<ErrorBanner errors={submission.errors} />

<p class="mb-3 flex items-center gap-2 text-sm" data-testid="suggestion-status">
  <StatusBadge status={suggestionStatus(s.status)} />
  {#if s.live}<span class="dg-muted">The circle's prompt now</span>{/if}
  {#if s.running}<span class="dg-muted">Your notes judge it now</span>{/if}
</p>

<section class="dg-card mb-6 p-4">
  <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
    <dt class="dg-muted">Suggested by</dt>
    <dd>{s.author.name}</dd>
    <dt class="dg-muted">Suggested</dt>
    <dd>{relativeTime(s.created_at)}</dd>
    <dt class="dg-muted">Judges</dt>
    <dd data-testid="suggestion-judges">{s.judges.map((j) => j.name).join(', ')}</dd>
    {#if s.decided_at}
      <dt class="dg-muted">Decided</dt>
      <dd>{relativeTime(s.decided_at)}</dd>
    {/if}
    {#if s.pull_request_url}
      <dt class="dg-muted">Pull request</dt>
      <dd><a class="dg-link break-all" href={s.pull_request_url}>{s.pull_request_url}</a></dd>
    {:else if s.pull_request_owed}
      <dt class="dg-muted">Pull request</dt>
      <dd>Opened by your next nightly run</dd>
    {/if}
  </dl>
</section>

<h2 class="dg-label mb-2">Rounds</h2>
<ul class="dg-card dg-rows mb-6 overflow-hidden" aria-label="Rounds">
  {#each s.rounds as r (r.number)}
    <li class="px-4 py-3 text-sm" data-testid="suggestion-round">
      <p class="font-medium">Round {r.number} · {roundResult(r.result)}</p>
      <ul class="dg-muted mt-1 text-xs">
        {#each r.picks as p (p.judge.identity)}
          <li>{p.judge.name} picked {promptPick(p.pick)} · {relativeTime(p.at)}</li>
        {/each}
      </ul>
    </li>
  {:else}
    <li class="dg-muted px-4 py-6 text-center text-sm">No picks yet</li>
  {/each}
</ul>

{#if s.text !== ''}
  <h2 class="dg-label mb-2">Prompt</h2>
  <div class="dg-card p-4">
    <p class="font-mono text-xs whitespace-pre-wrap" data-testid="suggestion-text">{s.text}</p>
  </div>
{/if}

{#if s.can_withdraw}
  <div class="mt-6 border-t border-stone-200 pt-4 dark:border-stone-800">
    {#if confirming}
      <p class="mb-2 text-sm">Withdraw this suggestion? Its judges' notes go back to one version.</p>
      <div class="flex gap-2">
        <Button variant="danger" busy={submission.busy() && 'Withdrawing…'} onclick={handleWithdraw}>Withdraw</Button>
        <Button onclick={() => (confirming = false)} disabled={submission.busy()}>Cancel</Button>
      </div>
    {:else}
      <button type="button" class="min-h-11 text-sm text-red-700 hover:underline dark:text-red-300" onclick={() => (confirming = true)}
        >Withdraw suggestion</button
      >
    {/if}
  </div>
{/if}
