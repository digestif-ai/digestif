<script lang="ts">
  import { refreshAll } from '$app/navigation';
  import { createClient } from '#lib/api/client.ts';
  import Button from '#lib/components/Button.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import MessageBody from '#lib/components/MessageBody.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import { href } from '#lib/href.ts';
  import { Submission } from '#lib/submission.svelte.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const note = $derived(data.note);

  const client = createClient();
  const submission = new Submission();

  async function handleDecide(approve: boolean): Promise<void> {
    await submission.run(
      () => (approve ? client.approve(note.hash) : client.refuse(note.hash)),
      () => refreshAll(),
      approve ? 'approve' : 'refuse'
    );
  }
</script>

<PageHeader title="Nightly note" crumbs={[{ label: 'Approvals', href: href.approvals() }]} />
<ErrorBanner errors={submission.errors} />
<MessageBody message={note} />

{#if note.status === 'awaiting_approval'}
  <div class="mt-4 flex flex-wrap gap-2">
    <Button
      variant="primary"
      busy={submission.pending('approve') && 'Posting…'}
      disabled={submission.busy()}
      onclick={() => handleDecide(true)}>Approve and post</Button
    >
    <Button
      variant="danger"
      busy={submission.pending('refuse') && 'Dropping…'}
      disabled={submission.busy()}
      onclick={() => handleDecide(false)}>Drop</Button
    >
  </div>
{/if}
