<script lang="ts">
  import { createClient } from '#lib/api/client.ts';
  import Button from '#lib/components/Button.svelte';
  import Empty from '#lib/components/Empty.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import StatusBadge from '#lib/components/StatusBadge.svelte';
  import { messageStatus, relativeTime } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import { Submission } from '#lib/submission.svelte.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const q = $derived(data.queue);

  const client = createClient();
  const submission = new Submission();
  let requested = $state(false);

  async function handleWriteNow(): Promise<void> {
    await submission.run(
      () => client.writeNoteNow(),
      () => {
        requested = true;
      },
      'write'
    );
  }
</script>

<PageHeader title="Approvals">
  {#snippet actions()}
    <Button busy={submission.pending('write') && 'Asking…'} disabled={submission.busy() || requested} onclick={handleWriteNow}
      >Write a note now</Button
    >
  {/snippet}
</PageHeader>
<ErrorBanner errors={submission.errors} />
{#if requested}
  <p class="mb-4 text-sm" data-testid="write-note-requested">Writing a note from yesterday; it appears here in a minute or two.</p>
{/if}
<p class="mb-4 text-sm" data-testid="approval-progress">
  {Math.min(q.approved, q.required)} of {q.required} approved{q.approved >= q.required ? '; notes now go out unreviewed' : ''}
</p>
<ul class="dg-card dg-rows overflow-hidden" aria-label="Notes">
  {#each q.notes as note (note.hash)}
    <li>
      <a class="dg-row" href={href.approval(note.hash)} data-testid="approval-row">
        <div class="min-w-0 flex-1">
          <p class="truncate text-sm">{note.preview}</p>
          <p class="dg-muted text-xs">{relativeTime(note.created_at)}</p>
        </div>
        <StatusBadge status={messageStatus(note.status)} />
      </a>
    </li>
  {:else}
    <Empty text="No notes yet" />
  {/each}
</ul>
