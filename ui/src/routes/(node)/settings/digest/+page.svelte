<script lang="ts">
  import { goto } from '$app/navigation';
  import { createClient } from '#lib/api/client.ts';
  import Button from '#lib/components/Button.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import { noteTime } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import { Submission } from '#lib/submission.svelte.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  // svelte-ignore state_referenced_locally
  let email = $state(data.digest.email ?? '');
  // svelte-ignore state_referenced_locally
  let hour = $state(data.digest.hour);
  const hours = Array.from({ length: 24 }, (_, h) => h);

  const client = createClient();
  const submission = new Submission();

  async function handleSubmit(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    await submission.run(
      () => client.saveDigestSettings({ email, hour }),
      () => goto(href.settings(), { refreshAll: true })
    );
  }
</script>

<PageHeader title="Digest" crumbs={[{ label: 'Settings', href: href.settings() }]} />

<form class="dg-card p-4" onsubmit={handleSubmit}>
  <ErrorBanner errors={submission.generalErrors(['email', 'hour'])} />
  <label class="block">
    <span class="dg-label mb-1 block">Email</span>
    <input class="dg-input" type="text" inputmode="email" autocomplete="email" bind:value={email} />
    {#if submission.fieldError('email')}<span class="mt-1 block text-sm text-red-700 dark:text-red-300"
        >{submission.fieldError('email')}</span
      >{/if}
  </label>
  <label class="mt-3 block sm:w-48">
    <span class="dg-label mb-1 block">After</span>
    <select class="dg-input" bind:value={hour}>
      {#each hours as h (h)}
        <option value={h}>{noteTime(String(h) + ':00')}</option>
      {/each}
    </select>
    {#if submission.fieldError('hour')}<span class="mt-1 block text-sm text-red-700 dark:text-red-300">{submission.fieldError('hour')}</span
      >{/if}
  </label>
  <div class="mt-3 flex gap-2">
    <Button variant="primary" type="submit" busy={submission.busy() && 'Saving…'}>Save</Button>
    <Button href={href.settings()}>Cancel</Button>
  </div>
</form>
