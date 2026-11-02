<script lang="ts">
  import { goto, invalidateAll } from '$app/navigation';
  import { createClient } from '#lib/api/client.ts';
  import Button from '#lib/components/Button.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import StatusBadge from '#lib/components/StatusBadge.svelte';
  import { checksLine, noteDate, noteStatus } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import { Submission } from '#lib/submission.svelte.ts';
  import type { Note } from '#generated/com-bryzek-digestif-node.ts';
  import Tabs from './Tabs.svelte';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const note = $derived(data.note);
  const version = $derived(note.version);
  const newer = $derived(data.newer);

  const client = createClient();
  const submission = new Submission();
  let editing = $state(false);
  let text = $state('');

  function startEdit(): void {
    text = version?.text ?? '';
    editing = true;
  }

  /** An edit is a new version: the page moves to it, so the member sees its checks run. */
  async function save(approve: boolean): Promise<void> {
    if (version === undefined) return;
    await submission.run(
      () => client.editNote(note.id, { text, edited_version_id: version.id, approve }),
      async (saved: Note) => {
        editing = false;
        const id = saved.newer_version_id ?? saved.version?.id;
        await goto(id === undefined ? href.note(note.id) : href.note(note.id, id), { invalidateAll: true });
      },
      approve ? 'save-approve' : 'save'
    );
  }

  async function approve(): Promise<void> {
    if (version === undefined) return;
    await submission.run(
      () => client.approveNote(note.id, version.id),
      () => invalidateAll(),
      'approve'
    );
  }
</script>

<PageHeader title="{noteDate(note.written_at)} Note" crumbs={[{ label: 'Notes', href: href.notes() }]}>
  {#snippet actions()}
    {#if note.can_edit && !editing}
      <Button disabled={submission.busy()} onclick={startEdit}>Edit</Button>
    {/if}
    {#if note.can_approve && !editing}
      <Button variant="primary" busy={submission.pending('approve') && 'Approving…'} disabled={submission.busy()} onclick={approve}
        >Approve</Button
      >
    {/if}
  {/snippet}
</PageHeader>
<p class="mb-3 flex items-center gap-2 text-sm" data-testid="note-status">
  <StatusBadge status={noteStatus(note.status)} />
  {#if version !== undefined}<span class="dg-muted">Version {version.number}</span>{/if}
</p>
<Tabs id={note.id} current="note" />
<ErrorBanner errors={submission.errors} />
{#if note.not_sent !== undefined}
  <p class="mb-3 text-sm text-red-700 dark:text-red-300" data-testid="not-sent">{note.not_sent}</p>
{/if}
{#if newer !== undefined}
  <p class="mb-3 text-sm" data-testid="newer-version">
    Your edit made version {newer.number}.
    {#if newer.checks.pii === 'passed' && newer.checks.rules === 'passed'}
      <a class="dg-link" href={href.note(note.id, newer.id)}>Read version {newer.number}</a>
    {:else}
      {checksLine(newer.checks)}.
    {/if}
  </p>
{/if}
{#if editing}
  <div class="dg-card p-4">
    <label class="mb-2 block text-sm font-medium" for="note-text">Note</label>
    <textarea
      id="note-text"
      class="mb-3 min-h-60 w-full rounded-md border border-stone-300 p-2 text-sm dark:border-stone-700 dark:bg-stone-900"
      bind:value={text}></textarea>
    <div class="flex flex-wrap gap-2">
      <Button disabled={submission.busy()} onclick={() => (editing = false)}>Cancel</Button>
      <Button busy={submission.pending('save') && 'Saving…'} disabled={submission.busy()} onclick={() => save(false)}>Save</Button>
      <Button
        variant="primary"
        busy={submission.pending('save-approve') && 'Saving…'}
        disabled={submission.busy()}
        onclick={() => save(true)}>Save & approve</Button
      >
    </div>
  </div>
{:else if version === undefined}
  <p class="dg-muted text-sm">This note is still being written.</p>
{:else}
  <div class="dg-card p-4">
    {#if version.text === undefined}
      <p class="dg-muted text-sm" data-testid="checks-running">{checksLine(version.checks)}. It goes out if they remove nothing.</p>
    {:else}
      <p class="text-sm whitespace-pre-wrap" data-testid="note-text">{version.text}</p>
    {/if}
  </div>
  <p class="dg-muted mt-3 text-xs" data-testid="note-checks">Checks · {checksLine(version.checks)}</p>
{/if}
