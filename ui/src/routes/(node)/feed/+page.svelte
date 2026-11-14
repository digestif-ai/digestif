<script lang="ts">
  import { goto, invalidateAll, refreshAll } from '$app/navigation';
  import { Stage } from '#generated/ai-digestif-digestif-node.ts';
  import { createClient } from '#lib/api/client.ts';
  import ActionMenu, { type Action } from '#lib/components/ActionMenu.svelte';
  import Button from '#lib/components/Button.svelte';
  import Empty from '#lib/components/Empty.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import FeedRow from '#lib/components/FeedRow.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import { problemLines } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import { Submission } from '#lib/submission.svelte.ts';
  import { feedThreads } from '#lib/threads.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const problems = $derived(problemLines(data.problems));
  const active = $derived(data.status.stage === Stage.Active);
  // Each thread once, as its latest message; a thread of several opens on all of them (ISS-85464).
  const threads = $derived(feedThreads(data.feed));

  const client = createClient();
  const submission = new Submission();
  let writing = $state(false);

  /** Write a note now: the note writer runs on the node's next pass rather than at Note time. */
  async function handleWriteNow(): Promise<void> {
    await submission.run(
      () => client.writeNoteNow(),
      () => {
        writing = true;
      },
      'write'
    );
  }

  /** Pause sends the Paused note at once, and the whole app becomes the Paused page. */
  async function handlePause(): Promise<void> {
    await submission.run(
      () => client.pause(),
      async () => {
        await invalidateAll();
        await goto(href.paused());
      },
      'pause'
    );
  }

  /** The header's one button: Post, Write a note and Pause, each an item of its menu. */
  const menu = $derived.by(() => {
    const actions: Action[] = [];
    if (active) actions.push({ label: 'Post to the circle', href: href.post() });
    actions.push({ label: 'Write a note now', disabled: writing, onselect: () => void handleWriteNow() });
    if (active) actions.push({ label: 'Pause', onselect: () => void handlePause() });
    return actions;
  });
  const menuBusy = $derived((submission.pending('write') && 'Starting…') || (submission.pending('pause') && 'Pausing…') || false);

  async function handleNotNow(): Promise<void> {
    await submission.run(
      () => client.dismissSuggestion(),
      () => refreshAll(),
      'not-now'
    );
  }
</script>

<PageHeader title="Feed">
  {#snippet actions()}
    <ActionMenu label="Actions" actions={menu} busy={menuBusy} disabled={submission.busy()} />
  {/snippet}
</PageHeader>
{#each problems as line (line)}
  <p class="mb-2 text-sm text-red-700 dark:text-red-300" data-testid="problem-line">{line}</p>
{/each}
<ErrorBanner errors={submission.errors} />
{#if writing}
  <p class="mb-4 text-sm" role="status" data-testid="writing-now">Your agent writes a note on the node's next pass.</p>
{/if}
{#if data.notes.suggest_auto_approval}
  <div class="mb-4 flex flex-wrap items-center gap-2 text-sm" data-testid="auto-approval-suggestion">
    <p class="mr-auto">Your last five notes were approved with no change.</p>
    <Button variant="primary" href={href.approvalEdit('auto_approve')}>Turn on auto approval</Button>
    <Button busy={submission.pending('not-now') && 'Not now…'} disabled={submission.busy()} onclick={handleNotNow}>Not now</Button>
  </div>
{/if}
{#if data.notes.no_activity}
  <p class="mb-4 text-sm" data-testid="no-activity">No activity yet. You will hear when your first note is ready.</p>
{/if}
<ul class="dg-card dg-rows overflow-hidden" aria-label="Messages">
  {#each threads as t (t.key)}
    <FeedRow item={t.shown} count={t.rows.length} href={t.rows.length > 1 ? href.feedThread(t.key) : href.message(t.shown.hash)} />
  {:else}
    <Empty text="Nothing yet" />
  {/each}
</ul>
