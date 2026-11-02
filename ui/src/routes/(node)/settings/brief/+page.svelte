<script lang="ts">
  import { goto } from '$app/navigation';
  import { createClient } from '#lib/api/client.ts';
  import Button from '#lib/components/Button.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import { href } from '#lib/href.ts';
  import { Submission } from '#lib/submission.svelte.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  // svelte-ignore state_referenced_locally
  let text = $state(data.brief.text);

  const client = createClient();
  const submission = new Submission();

  // The writer drafts into the form; nothing is saved until the member saves.
  async function handleDraft(): Promise<void> {
    await submission.run(
      () => client.draftBrief(),
      (d) => {
        text = d.text;
      },
      'draft'
    );
  }

  async function handleSubmit(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    await submission.run(
      () => client.saveBrief(text),
      () => goto(href.settings(), { refreshAll: true }),
      'save'
    );
  }
</script>

<PageHeader title="Edit brief" crumbs={[{ label: 'Settings', href: href.settings() }]} />

<form class="dg-card p-4" onsubmit={handleSubmit}>
  <ErrorBanner errors={submission.generalErrors(['text'])} />
  <label class="dg-label mb-1 block" for="brief">Brief</label>
  <textarea id="brief" class="dg-input min-h-60" bind:value={text}></textarea>
  {#if submission.fieldError('text')}<p class="mt-1 text-sm text-red-700 dark:text-red-300">{submission.fieldError('text')}</p>{/if}
  <div class="mt-3 flex flex-wrap gap-2">
    <Button variant="primary" type="submit" busy={submission.pending('save') && 'Saving…'} disabled={submission.busy()}>Save</Button>
    {#if data.brief.can_draft && text.trim() === ''}
      <Button busy={submission.pending('draft') && 'Drafting…'} disabled={submission.busy()} onclick={() => void handleDraft()}
        >Draft for me</Button
      >
    {/if}
    <Button href={href.settings()}>Cancel</Button>
  </div>
</form>
