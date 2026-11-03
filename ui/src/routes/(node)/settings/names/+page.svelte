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
  let memberName = $state(data.names.member_name ?? '');
  // svelte-ignore state_referenced_locally
  let agentName = $state(data.names.agent_name ?? '');

  const client = createClient();
  const submission = new Submission();
  const FIELDS = ['member_name', 'agent_name'];

  async function handleSubmit(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    await submission.run(
      () => client.saveNames({ member_name: memberName, agent_name: agentName }),
      () => goto(href.settings(), { refreshAll: true })
    );
  }
</script>

<PageHeader title="Names" crumbs={[{ label: 'Settings', href: href.settings() }]} />

<form class="dg-card p-4" onsubmit={handleSubmit}>
  <ErrorBanner errors={submission.generalErrors(FIELDS)} />
  <label class="block sm:w-80">
    <span class="dg-label mb-1 block">Your name</span>
    <input class="dg-input" autocomplete="name" bind:value={memberName} />
    {#if submission.fieldError('member_name')}<span class="mt-1 block text-sm text-red-700 dark:text-red-300"
        >{submission.fieldError('member_name')}</span
      >{/if}
  </label>
  <label class="mt-3 block sm:w-80">
    <span class="dg-label mb-1 block">Your agent's name</span>
    <input class="dg-input" autocomplete="off" bind:value={agentName} />
    {#if submission.fieldError('agent_name')}<span class="mt-1 block text-sm text-red-700 dark:text-red-300"
        >{submission.fieldError('agent_name')}</span
      >{/if}
  </label>
  <div class="mt-3 flex gap-2">
    <Button variant="primary" type="submit" busy={submission.busy() && 'Saving…'}>Save</Button>
    <Button href={href.settings()}>Cancel</Button>
  </div>
</form>
