<script lang="ts">
  import { goto, refreshAll } from '$app/navigation';
  import { createClient } from '#lib/api/client.ts';
  import { SourceKind, type NotePreview } from '#generated/com-bryzek-digestif-node.ts';
  import Button from '#lib/components/Button.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import SourceSummary from '#lib/components/SourceSummary.svelte';
  import { href } from '#lib/href.ts';
  import { Submission } from '#lib/submission.svelte.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const firstRun = $derived(data.status.first_run);

  // Nothing is selected until the member chooses; the node answers selected: false on first run.
  // svelte-ignore state_referenced_locally
  let selected = $state<string[]>(data.sources.filter((s) => s.selected).map((s) => s.id));
  let preview = $state<NotePreview | undefined>(undefined);
  let previewedFor = $state('');
  const key = $derived([...selected].sort().join(','));
  const previewCurrent = $derived(preview !== undefined && previewedFor === key);

  const client = createClient();
  const submission = new Submission();

  function handleToggle(id: string): void {
    selected = selected.includes(id) ? selected.filter((x) => x !== id) : [...selected, id];
  }

  async function handlePreview(): Promise<void> {
    const forKey = key;
    await submission.run(
      () => client.preview(selected),
      (p) => {
        preview = p;
        previewedFor = forKey;
      },
      'preview'
    );
  }

  // A command source: the member's own program (docs/behaviors.md, Command sources). Arguments are
  // split on spaces; the node appends --since.
  let adding = $state(false);
  let label = $state('');
  let program = $state('');
  let args = $state('');

  async function handleAdd(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    const command = [program.trim(), ...args.split(/\s+/).filter((a) => a !== '')];
    await submission.run(
      () => client.addSource({ label: label, command: command }),
      async () => {
        label = '';
        program = '';
        args = '';
        adding = false;
        await refreshAll();
      },
      'add'
    );
  }

  async function handleRemove(id: string): Promise<void> {
    await submission.run(
      () => client.removeSource(id),
      async () => {
        selected = selected.filter((x) => x !== id);
        await refreshAll();
      },
      'remove-' + id
    );
  }

  async function handleSave(): Promise<void> {
    await submission.run(
      () => client.saveSources(selected),
      () => goto(firstRun ? href.feed() : href.sources(), { refreshAll: true }),
      'save'
    );
  }
</script>

<PageHeader
  title={firstRun ? 'Choose what your agent may read' : 'Edit sources'}
  crumbs={firstRun ? [] : [{ label: 'Sources', href: href.sources() }]}
/>
<ErrorBanner errors={submission.errors} />

<fieldset class="dg-card dg-rows overflow-hidden">
  <legend class="sr-only">Sources</legend>
  {#each data.sources as source (source.id)}
    <label class="dg-row cursor-pointer items-start">
      <input
        type="checkbox"
        class="mt-1 size-5 rounded border-stone-400 text-dg-accent focus:ring-dg-accent"
        checked={selected.includes(source.id)}
        onchange={() => handleToggle(source.id)}
        data-testid="source-{source.id}"
      />
      <SourceSummary {source} />
      {#if source.kind === SourceKind.Command}
        <Button
          variant="danger"
          busy={submission.pending('remove-' + source.id) && 'Removing…'}
          disabled={submission.busy()}
          onclick={() => void handleRemove(source.id)}>Remove</Button
        >
      {/if}
    </label>
  {/each}
</fieldset>

{#if adding}
  <form class="dg-card mt-4 p-4" onsubmit={handleAdd} aria-label="Add a command source">
    <ErrorBanner errors={submission.generalErrors(['label', 'command'])} />
    <div class="flex flex-col gap-3">
      <label>
        <span class="dg-label mb-1 block">Name</span>
        <input class="dg-input" bind:value={label} placeholder="Athena" />
        {#if submission.fieldError('label')}<span class="mt-1 block text-sm text-red-700 dark:text-red-300"
            >{submission.fieldError('label')}</span
          >{/if}
      </label>
      <label>
        <span class="dg-label mb-1 block">Program</span>
        <input class="dg-input font-mono" bind:value={program} placeholder="/usr/local/bin/athena" />
        {#if submission.fieldError('command')}<span class="mt-1 block text-sm text-red-700 dark:text-red-300"
            >{submission.fieldError('command')}</span
          >{/if}
      </label>
      <label>
        <span class="dg-label mb-1 block">Arguments</span>
        <input class="dg-input font-mono" bind:value={args} placeholder="activity --project digestif" />
      </label>
    </div>
    <div class="mt-3 flex gap-2">
      <Button variant="primary" type="submit" busy={submission.pending('add') && 'Adding…'} disabled={submission.busy()}>Add</Button>
      <Button onclick={() => (adding = false)} disabled={submission.busy()}>Cancel</Button>
    </div>
  </form>
{:else}
  <div class="mt-3"><Button onclick={() => (adding = true)}>Add a command source</Button></div>
{/if}

<section class="mt-6" aria-labelledby="preview-heading">
  <div class="mb-2 flex items-center justify-between gap-3">
    <h2 id="preview-heading" class="dg-label">First note preview</h2>
    <Button busy={submission.pending('preview') && 'Drafting…'} disabled={submission.busy()} onclick={handlePreview}>Preview</Button>
  </div>
  <div class="dg-card p-4" data-testid="preview">
    {#if preview === undefined}
      <p class="dg-muted text-sm">Preview shows exactly what would leave this machine tonight.</p>
    {:else}
      {#if !previewCurrent}<p class="mb-2 text-sm text-amber-800 dark:text-amber-300">The selection changed since this preview.</p>{/if}
      {#if preview.text !== undefined}
        <p class="whitespace-pre-wrap" data-testid="preview-text">{preview.text}</p>
      {:else if preview.refused_rule !== undefined}
        <p class="text-sm text-red-700 dark:text-red-300">
          The deny layer refused this note ({preview.refused_rule}). Nothing would be sent.
        </p>
      {:else}
        <p class="dg-muted text-sm">No sources: no nightly note. You can still read and answer.</p>
      {/if}
      {#if preview.extracted.length > 0}
        <h3 class="dg-label mt-4 mb-1">What the writer was given</h3>
        <ul class="dg-muted list-disc pl-5 text-sm">
          {#each preview.extracted as line, i (i)}<li class="break-words">{line}</li>{/each}
        </ul>
      {/if}
    {/if}
  </div>
</section>

<div class="mt-6 flex flex-wrap gap-2">
  <Button variant="primary" busy={submission.pending('save') && 'Saving…'} disabled={submission.busy()} onclick={handleSave}>
    {firstRun && selected.length === 0 ? 'Join with no sources' : 'Save'}
  </Button>
  {#if !firstRun}<Button href={href.sources()}>Cancel</Button>{/if}
</div>
