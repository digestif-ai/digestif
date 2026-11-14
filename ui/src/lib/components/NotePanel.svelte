<script lang="ts">
  import { goto, invalidateAll } from '$app/navigation';
  import {
    NoteProgressState,
    NoteStep,
    type LogEntry,
    type Message,
    type Note,
    type NoteVersion
  } from '#generated/ai-digestif-digestif-node.ts';
  import { createClient } from '../api/client.ts';
  import { checksLine, logRows, messageStatus, noteDate, noteStatus, relativeTime } from '../format.ts';
  import { href } from '../href.ts';
  import { Submission } from '../submission.svelte.ts';
  import ActionMenu, { type Action } from './ActionMenu.svelte';
  import Button from './Button.svelte';
  import Empty from './Empty.svelte';
  import ErrorBanner from './ErrorBanner.svelte';
  import MessageBody from './MessageBody.svelte';
  import PageHeader from './PageHeader.svelte';
  import StatusBadge from './StatusBadge.svelte';

  // A note is approved on its message (ISS-47299): Approve, Edit with Save & approve, and Dismiss in
  // the header's one menu, then the note, its versions and its Log. The first note before the run hands it over
  // shows how far the run has got instead.
  interface Props {
    message: Message;
    note: Note;
    /** The version an edit made, when it is newer than the one being read. */
    newer: NoteVersion | undefined;
    versions: NoteVersion[];
    log: LogEntry[];
  }

  let { message, note, newer, versions, log }: Props = $props();
  const version = $derived(note.version);
  const progress = $derived(note.progress);
  const waiting = $derived(note.status === 'waiting' && progress === undefined);
  /** Two versions for a suggestion this member judges (ISS-51009): approving or editing one is the pick. */
  const pair = $derived(note.pair);

  const STEP_LABELS: Record<NoteStep, string> = {
    [NoteStep.Reading]: 'Reading your sources',
    [NoteStep.Writing]: 'Writing your note',
    [NoteStep.Checking]: 'Checking your note'
  };

  $effect(() => {
    if (progress?.state === NoteProgressState.Writing) {
      const timer = setInterval(() => void invalidateAll(), 3000);
      return () => clearInterval(timer);
    }
    return undefined;
  });

  const client = createClient();
  const submission = new Submission();
  let editing = $state(false);
  let text = $state('');
  /** The version an edit started from: the page's, or the one of a pair it was opened on. */
  let editFrom = $state<NoteVersion | undefined>(undefined);

  function startEdit(from: NoteVersion | undefined = version): void {
    editFrom = from;
    text = from?.text ?? '';
    editing = true;
  }

  /** An edit is a new version: the page moves to it, so the member sees its checks run. */
  async function save(approve: boolean): Promise<void> {
    const from = editFrom ?? version;
    if (from === undefined) return;
    await submission.run(
      () => client.editNote(note.id, { text, edited_version_id: from.id, approve }),
      async (saved: Note) => {
        editing = false;
        const id = saved.newer_version_id ?? saved.version?.id;
        await goto(href.note(note.id, id), { invalidateAll: true });
      },
      approve ? 'save-approve' : 'save'
    );
  }

  async function approve(v: NoteVersion | undefined = version): Promise<void> {
    if (v === undefined) return;
    await submission.run(
      () => client.approveNote(note.id, v.id),
      () => invalidateAll(),
      'approve-' + v.id
    );
  }

  /** Write it now: no run is writing the first note, so the node's next pass starts one. ISS-48141 */
  async function writeNow(): Promise<void> {
    await submission.run(
      () => client.writeNoteNow(),
      () => invalidateAll(),
      'write-now'
    );
  }

  /** Dismiss discards the note before it is approved: it is never sent. */
  async function dismiss(): Promise<void> {
    await submission.run(
      () => client.dismissNote(note.id),
      async () => {
        await goto(href.feed(), { invalidateAll: true });
      },
      'dismiss'
    );
  }

  /** The header's one button (ISS-85465): Approve, Edit and Dismiss, each an item of its menu. */
  const menu = $derived.by(() => {
    const actions: Action[] = [];
    if (editing) return actions;
    if (note.can_approve && pair === undefined) actions.push({ label: 'Approve', onselect: () => void approve() });
    if (note.can_edit && pair === undefined) actions.push({ label: 'Edit', onselect: () => startEdit() });
    if (waiting) actions.push({ label: 'Dismiss', onselect: () => void dismiss() });
    return actions;
  });
  const menuBusy = $derived(
    (submission.pending('approve-' + (version?.id ?? '')) && 'Approving…') || (submission.pending('dismiss') && 'Dismissing…') || false
  );

  const by = (v: NoteVersion): string => (v.voice === 'person' ? 'your edit' : 'your agent');
</script>

<PageHeader
  title={progress === undefined ? `${noteDate(note.written_at)} Note` : 'Your first note'}
  crumbs={[{ label: 'Feed', href: href.feed() }]}
>
  {#snippet actions()}
    <ActionMenu label="Actions" actions={menu} busy={menuBusy} disabled={submission.busy()} />
  {/snippet}
</PageHeader>
{#if progress === undefined}
  <p class="mb-3 flex items-center gap-2 text-sm" data-testid="note-status">
    <StatusBadge status={messageStatus(message.status)} />
    {#if note.status === 'approved' || note.status === 'auto_approved'}<StatusBadge status={noteStatus(note.status)} />{/if}
    {#if version !== undefined && pair === undefined}<span class="dg-muted">Version {version.number}</span>{/if}
  </p>
{/if}
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
{:else if progress !== undefined}
  <div class="dg-card p-4" data-testid="note-progress">
    {#if progress.state === NoteProgressState.NoActivity}
      <p>No activity yet. You will hear when your first note is ready.</p>
    {:else if progress.state === NoteProgressState.Failed}
      <p class="text-red-700 dark:text-red-300">{progress.message}</p>
    {:else if progress.state === NoteProgressState.Stopped}
      <p class="mb-3">Nothing is writing your note right now: the last run stopped before it finished.</p>
      <Button variant="primary" busy={submission.pending('write-now') && 'Starting…'} disabled={submission.busy()} onclick={writeNow}
        >Write it now</Button
      >
    {:else}
      <p>{progress.step === undefined ? 'Starting' : STEP_LABELS[progress.step]}…</p>
      {#if progress.sources.length > 0}
        <ul class="dg-muted mt-2 list-disc pl-5 text-sm">
          {#each progress.sources as source (source)}<li>{source}</li>{/each}
        </ul>
      {/if}
    {/if}
  </div>
{:else if pair !== undefined}
  <p class="mb-3 text-sm" data-testid="note-pair-intro">Two versions tonight. Approve the one you would send.</p>
  <div class="grid gap-4 md:grid-cols-2" data-testid="note-pair">
    {#each pair as v (v.id)}
      <div class="dg-card flex flex-col p-4" data-testid="pair-version">
        <p class="mb-3 flex-1 text-sm whitespace-pre-wrap">{v.text ?? checksLine(v.checks) + '.'}</p>
        <p class="dg-muted mb-3 text-xs">Checks · {checksLine(v.checks)}</p>
        <div class="flex flex-wrap gap-2">
          {#if note.can_approve && v.text !== undefined && v.text !== ''}
            <Button
              variant="primary"
              busy={submission.pending('approve-' + v.id) && 'Approving…'}
              disabled={submission.busy()}
              onclick={() => approve(v)}>Approve this one</Button
            >
          {/if}
          {#if note.can_edit}
            <Button disabled={submission.busy()} onclick={() => startEdit(v)}>Edit this one</Button>
          {/if}
        </div>
      </div>
    {/each}
  </div>
{:else if message.status === 'posted'}
  <MessageBody {message} />
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

{#if progress === undefined}
  <h2 class="dg-label mt-6 mb-2">Versions</h2>
  <ul class="dg-card dg-rows overflow-hidden" aria-label="Versions">
    {#each versions as v (v.id)}
      <li>
        <a
          class="dg-row"
          href={href.note(note.id, v.id)}
          aria-current={version?.id === v.id ? 'true' : undefined}
          data-testid="version-row"
        >
          <span class="text-sm font-medium">Version {v.number}</span>
          <span class="dg-muted text-xs">{by(v)} · {checksLine(v.checks)}</span>
          <span class="dg-muted ml-auto text-xs">{relativeTime(v.created_at)}</span>
        </a>
      </li>
    {:else}
      <li><Empty text="No version yet" /></li>
    {/each}
  </ul>

  <h2 class="dg-label mt-6 mb-2">Log</h2>
  <ul class="dg-card dg-rows" aria-label="Log">
    {#each logRows(log) as row, i (i)}
      <li class="flex flex-wrap justify-between gap-2 px-4 py-3 text-sm" data-testid="log-entry">
        <span>{row.line}</span>
        <span class="dg-muted text-xs">{relativeTime(row.at)}</span>
        {#if row.passages.length > 0}
          <ul class="w-full space-y-1" aria-label="Removed" data-testid="log-passages">
            {#each row.passages as passage, j (j)}
              <li class="dg-muted border-l-2 pl-3 text-xs break-words whitespace-pre-wrap">{passage}</li>
            {/each}
          </ul>
        {/if}
      </li>
    {:else}
      <li><Empty text="Nothing yet" /></li>
    {/each}
  </ul>
{/if}
