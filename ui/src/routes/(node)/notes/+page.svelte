<script lang="ts">
  import { goto, invalidateAll, refreshAll } from '$app/navigation';
  import { Stage } from '#generated/com-bryzek-digestif-node.ts';
  import { createClient } from '#lib/api/client.ts';
  import Button from '#lib/components/Button.svelte';
  import Empty from '#lib/components/Empty.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import StatusBadge from '#lib/components/StatusBadge.svelte';
  import { noteDate, noteStatus, problemLines, relativeTime } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import { Submission } from '#lib/submission.svelte.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const notes = $derived(data.notes);
  const problems = $derived(problemLines(data.problems));

  const client = createClient();
  const submission = new Submission();

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

  async function handleNotNow(): Promise<void> {
    await submission.run(
      () => client.dismissSuggestion(),
      () => refreshAll(),
      'not-now'
    );
  }
</script>

<PageHeader title="Notes">
  {#snippet actions()}
    {#if data.status.stage === Stage.Active}
      <Button busy={submission.pending('pause') && 'Pausing…'} disabled={submission.busy()} onclick={handlePause}>Pause</Button>
    {/if}
  {/snippet}
</PageHeader>
{#each problems as line (line)}
  <p class="mb-2 text-sm text-red-700 dark:text-red-300" data-testid="problem-line">{line}</p>
{/each}
<ErrorBanner errors={submission.errors} />
{#if notes.suggest_auto_approval}
  <div class="mb-4 flex flex-wrap items-center gap-2 text-sm" data-testid="auto-approval-suggestion">
    <p class="mr-auto">Your last three notes were approved with no change.</p>
    <Button variant="primary" href={href.approvalEdit('auto_approve')}>Turn on auto approval</Button>
    <Button busy={submission.pending('not-now') && 'Not now…'} disabled={submission.busy()} onclick={handleNotNow}>Not now</Button>
  </div>
{/if}
{#if notes.no_activity}
  <p class="mb-4 text-sm" data-testid="no-activity">No activity yet. You will hear when your first note is ready.</p>
{/if}
<div class="dg-card overflow-hidden">
  <table class="w-full text-left text-sm" aria-label="Notes">
    <thead class="dg-muted text-xs">
      <tr>
        <th scope="col" class="px-3 py-2 font-medium">Note</th>
        <th scope="col" class="px-3 py-2 font-medium">Status</th>
        <th scope="col" class="hidden px-3 py-2 font-medium sm:table-cell">Shared</th>
      </tr>
    </thead>
    <tbody>
      {#each notes.notes as note (note.id)}
        <tr class="border-t border-stone-200 hover:bg-stone-50 dark:border-stone-800 dark:hover:bg-stone-900" data-testid="note-row">
          <td class="px-3 py-2">
            <a class="block min-h-11 py-1" href={href.note(note.id)}>
              <span class="font-medium">{noteDate(note.written_at)} Note</span>
              {#if note.preview}<span class="dg-muted block truncate text-xs">{note.preview}</span>{/if}
            </a>
          </td>
          <td class="px-3 py-2"><a href={href.note(note.id)} tabindex="-1"><StatusBadge status={noteStatus(note.status)} /></a></td>
          <td class="dg-muted hidden px-3 py-2 sm:table-cell">
            <a href={href.note(note.id)} tabindex="-1">{note.shared_at === undefined ? '' : relativeTime(note.shared_at)}</a>
          </td>
        </tr>
      {:else}
        <tr><td colspan="3"><Empty text="No notes yet" /></td></tr>
      {/each}
    </tbody>
  </table>
</div>
