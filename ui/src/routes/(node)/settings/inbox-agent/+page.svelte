<script lang="ts">
  import { invalidateAll } from '$app/navigation';
  import { createClient } from '#lib/api/client.ts';
  import Button from '#lib/components/Button.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import { noteDate, relativeTime } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import { Submission } from '#lib/submission.svelte.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const prompt = $derived(data.prompt);

  const client = createClient();
  const submission = new Submission();

  async function reset(): Promise<void> {
    await submission.run(
      () => client.resetInboxAgent(),
      () => invalidateAll()
    );
  }
</script>

<PageHeader title="Inbox agent" crumbs={[{ label: 'Settings', href: href.settings() }]}>
  {#snippet actions()}
    <Button href={href.inboxAgentEdit()}>Edit</Button>
    <Button onclick={reset} disabled={prompt.is_default} busy={submission.busy() && 'Resetting…'}>Reset to default</Button>
  {/snippet}
</PageHeader>

<ErrorBanner errors={submission.errors} />
<div class="dg-card p-4">
  <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
    <dt class="dg-muted">Prompt</dt>
    <dd data-testid="inbox-agent-origin">
      {#if prompt.is_default}The default{:else if prompt.updated_at}Edited {noteDate(prompt.updated_at)}, from the default{:else}Edited,
        from the default{/if}
    </dd>
    <dt class="dg-muted">Reviewed</dt>
    <dd data-testid="inbox-agent-reviewed">
      {prompt.reviewed}
      {prompt.reviewed === 1 ? 'message' : 'messages'}{#if prompt.last_reviewed_at}, the last {relativeTime(prompt.last_reviewed_at)}{/if}
    </dd>
  </dl>
  <p class="mt-4 text-sm whitespace-pre-wrap" data-testid="inbox-agent-text">{prompt.text}</p>
</div>
