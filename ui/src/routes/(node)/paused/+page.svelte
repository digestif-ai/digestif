<script lang="ts">
  import { goto, invalidateAll } from '$app/navigation';
  import { createClient } from '#lib/api/client.ts';
  import Button from '#lib/components/Button.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import { noteDate } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import { nextNoteWords, pausedSince, UNPAUSE_WORDS } from '#lib/pause.ts';
  import { Submission } from '#lib/submission.svelte.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const paused = $derived(data.paused);

  const client = createClient();
  const submission = new Submission();

  async function handleUnpause(): Promise<void> {
    await submission.run(
      () => client.unpause(),
      async () => {
        await invalidateAll();
        await goto(href.notes());
      }
    );
  }
</script>

<PageHeader title="Paused">
  {#snippet actions()}
    <Button variant="primary" busy={submission.pending() && 'Unpausing…'} onclick={handleUnpause}>Unpause</Button>
  {/snippet}
</PageHeader>
<ErrorBanner errors={submission.errors} />
<p class="max-w-prose text-sm leading-6" data-testid="paused-paragraph">
  {pausedSince(paused.since, paused.reason)}
  {UNPAUSE_WORDS}
  {#if paused.waiting_note}
    <!-- Named, not linked: nothing else opens while Paused, and Unpause lands on Notes. -->
    Your next note comes once your {noteDate(paused.waiting_note.written_at)} note goes out.
  {:else}
    {nextNoteWords(paused.note_time)}
  {/if}
</p>
