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
  let time = $state(data.noteTime.time);

  const client = createClient();
  const submission = new Submission();

  async function handleSubmit(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    await submission.run(
      () => client.saveNoteTime(time),
      () => goto(href.settings(), { refreshAll: true })
    );
  }
</script>

<PageHeader title="Note time" crumbs={[{ label: 'Settings', href: href.settings() }]} />

<form class="dg-card p-4" onsubmit={handleSubmit}>
  <ErrorBanner errors={submission.generalErrors(['time'])} />
  <label class="block sm:w-48">
    <span class="dg-label mb-1 block">Note time</span>
    <input class="dg-input" type="time" bind:value={time} />
    {#if submission.fieldError('time')}<span class="mt-1 block text-sm text-red-700 dark:text-red-300">{submission.fieldError('time')}</span
      >{/if}
  </label>
  <p class="dg-muted mt-2 text-xs">{data.noteTime.time_zone}</p>
  <div class="mt-3 flex gap-2">
    <Button variant="primary" type="submit" busy={submission.busy() && 'Saving…'}>Save</Button>
    <Button href={href.settings()}>Cancel</Button>
  </div>
</form>
