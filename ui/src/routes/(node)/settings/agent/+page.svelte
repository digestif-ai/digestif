<script lang="ts">
  import { AgentCheckStatus, type AgentCheck } from '#generated/com-bryzek-digestif-node.ts';
  import { createClient, isApiError } from '#lib/api/client.ts';
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
  let agentPath = $state(data.check?.status === AgentCheckStatus.Checking ? data.check.path : (data.agent?.path ?? ''));
  // The check Save started runs on the node for up to minutes; the page reads it until it ends.
  // svelte-ignore state_referenced_locally
  let check = $state<AgentCheck | undefined>(data.check);

  const client = createClient();
  const submission = new Submission();
  const checking = $derived(check?.status === AgentCheckStatus.Checking);

  $effect(() => {
    if (!checking) return undefined;
    const timer = setInterval(() => {
      void client.agentCheck().then((response) => {
        if (!isApiError(response)) check = response.data;
      });
    }, 1000);
    return () => clearInterval(timer);
  });

  async function handleSubmit(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    await submission.run(
      () => client.saveAgent(agentPath),
      (started) => {
        check = started;
      }
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
      disabled={checking}
      bind:value={agentPath}
    />
    {#if submission.fieldError('path')}<span class="mt-1 block text-sm text-red-700 dark:text-red-300" data-testid="agent-error"
        >{submission.fieldError('path')}</span
      >{:else if check?.status === AgentCheckStatus.Failed}<span
        class="mt-1 block text-sm text-red-700 dark:text-red-300"
        data-testid="agent-error">{check.message}</span
      >{/if}
  </label>
  {#if check !== undefined && check.status !== AgentCheckStatus.Failed}
    <p class="mt-3 text-sm" data-testid="agent-check">
      {#if checking}Checking {check.name}…{:else}{check.name} passed the check and is saved.{/if}
    </p>
  {/if}
  <div class="mt-3 flex gap-2">
    <Button variant="primary" type="submit" busy={(submission.busy() || checking) && 'Checking…'}>Save</Button>
    <Button href={href.settings()}>{check?.status === AgentCheckStatus.Passed ? 'Done' : 'Cancel'}</Button>
  </div>
</form>
