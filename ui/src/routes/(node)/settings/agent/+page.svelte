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
  let agentPath = $state(data.agent?.path ?? '');

  const client = createClient();
  const submission = new Submission();

  async function handleSubmit(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    await submission.run(
      () => client.saveAgent(agentPath),
      () => goto(href.settings(), { refreshAll: true })
    );
  }
</script>

<PageHeader title="Agent" crumbs={[{ label: 'Settings', href: href.settings() }]} />

<form class="dg-card p-4" onsubmit={handleSubmit}>
  <ErrorBanner errors={submission.generalErrors(['path'])} />
  <label class="block">
    <span class="dg-label mb-1 block">Program</span>
    <input
      class="dg-input font-mono text-sm"
      autocomplete="off"
      autocapitalize="off"
      spellcheck="false"
      placeholder="claude"
      bind:value={agentPath}
    />
    {#if submission.fieldError('path')}<span class="mt-1 block text-sm text-red-700 dark:text-red-300" data-testid="agent-error"
        >{submission.fieldError('path')}</span
      >{/if}
  </label>
  <div class="mt-3 flex gap-2">
    <Button variant="primary" type="submit" busy={submission.busy() && 'Checking…'}>Save</Button>
    <Button href={href.settings()}>Cancel</Button>
  </div>
</form>
