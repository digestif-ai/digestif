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
  let start = $state(data.rules.quiet_hours?.start ?? '22:00');
  // svelte-ignore state_referenced_locally
  let end = $state(data.rules.quiet_hours?.end ?? '07:00');

  const client = createClient();
  const submission = new Submission();
  let clearing = $state(false);

  async function handleSubmit(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    clearing = false;
    await submission.run(
      () => client.saveQuietHours(start, end),
      () => goto(href.settings(), { refreshAll: true })
    );
  }

  async function handleClear(): Promise<void> {
    clearing = true;
    await submission.run(
      () => client.clearQuietHours(),
      () => goto(href.settings(), { refreshAll: true })
    );
  }
</script>

<PageHeader title="Quiet hours" crumbs={[{ label: 'Settings', href: href.settings() }]} />

<form class="dg-card p-4" onsubmit={handleSubmit} aria-label="Quiet hours">
  <ErrorBanner errors={submission.generalErrors(['start', 'end'])} />
  <div class="flex flex-col gap-3 sm:flex-row">
    <label class="sm:w-40">
      <span class="dg-label mb-1 block">From</span>
      <input class="dg-input" type="time" bind:value={start} />
      {#if submission.fieldError('start')}<span class="mt-1 block text-sm text-red-700 dark:text-red-300"
          >{submission.fieldError('start')}</span
        >{/if}
    </label>
    <label class="sm:w-40">
      <span class="dg-label mb-1 block">To</span>
      <input class="dg-input" type="time" bind:value={end} />
      {#if submission.fieldError('end')}<span class="mt-1 block text-sm text-red-700 dark:text-red-300">{submission.fieldError('end')}</span
        >{/if}
    </label>
  </div>
  <div class="mt-3 flex gap-2">
    <Button variant="primary" type="submit" busy={submission.busy() && !clearing && 'Saving…'} disabled={submission.busy()}>Save</Button>
    {#if data.rules.quiet_hours}
      <Button onclick={() => void handleClear()} busy={submission.busy() && clearing && 'Clearing…'} disabled={submission.busy()}
        >Clear</Button
      >
    {/if}
    <Button href={href.settings()}>Cancel</Button>
  </div>
</form>
