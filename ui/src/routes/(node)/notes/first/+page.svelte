<script lang="ts">
  import { goto, refreshAll } from '$app/navigation';
  import { FirstNoteState, NoteStep } from '#generated/com-bryzek-digestif-node.ts';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import { href } from '#lib/href.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();

  // A state of the note page: the steps of the run, then the note itself once it waits.
  const STEP_LABELS: Record<NoteStep, string> = {
    [NoteStep.Reading]: 'Reading your sources',
    [NoteStep.Writing]: 'Writing your note',
    [NoteStep.Checking]: 'Checking your note'
  };

  const note = $derived(data.firstNote);

  $effect(() => {
    if (note?.state === FirstNoteState.Waiting && note.note !== undefined) {
      void goto(href.approval(note.note), { replaceState: true });
    }
  });

  $effect(() => {
    if (note === undefined || note.state === FirstNoteState.Writing) {
      const timer = setInterval(() => void refreshAll(), 3000);
      return () => clearInterval(timer);
    }
    return undefined;
  });
</script>

<PageHeader title="Your first note" />

<div class="dg-card p-4" data-testid="first-note">
  {#if note === undefined}
    <p>Setup continues in your terminal: <code>~/.local/bin/digestif setup</code></p>
  {:else if note.state === FirstNoteState.NoActivity}
    <p>No activity yet. You will hear when your first note is ready.</p>
  {:else if note.state === FirstNoteState.Failed}
    <p class="text-red-700 dark:text-red-300">{note.message}</p>
  {:else if note.state === FirstNoteState.Waiting}
    <p>Your first note is ready.</p>
  {:else}
    <p>{note.step === undefined ? 'Starting' : STEP_LABELS[note.step]}…</p>
    {#if note.sources !== undefined && note.sources.length > 0}
      <ul class="dg-muted mt-2 list-disc pl-5 text-sm">
        {#each note.sources as source (source)}<li>{source}</li>{/each}
      </ul>
    {/if}
    <p class="dg-muted mt-2 text-sm">Setup is done when this note is approved.</p>
  {/if}
</div>
