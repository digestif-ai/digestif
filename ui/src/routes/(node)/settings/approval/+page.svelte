<script lang="ts">
  import { goto } from '$app/navigation';
  import { page } from '$app/state';
  import { ApprovalSetting } from '#generated/com-bryzek-digestif-node.ts';
  import { createClient } from '#lib/api/client.ts';
  import Button from '#lib/components/Button.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import { approvalSetting } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import { Submission } from '#lib/submission.svelte.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const CHOICES: ApprovalSetting[] = [ApprovalSetting.EveryNoteWaits, ApprovalSetting.AutoApprove];
  // ?setting=auto_approve preselects a choice (the suggestion on Notes opens it so); nothing is saved
  // until Save.
  const asked = page.url.searchParams.get('setting');
  // svelte-ignore state_referenced_locally
  let setting = $state<ApprovalSetting>(CHOICES.find((c) => c === asked) ?? data.approval.setting);

  const client = createClient();
  const submission = new Submission();

  async function handleSubmit(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    await submission.run(
      () => client.saveApprovalSetting(setting),
      () => goto(href.settings(), { refreshAll: true })
    );
  }
</script>

<PageHeader title="Approval" crumbs={[{ label: 'Settings', href: href.settings() }]} />

<form class="dg-card p-4" onsubmit={handleSubmit} aria-label="Approval">
  <ErrorBanner errors={submission.errors} />
  <fieldset class="flex flex-col gap-2">
    <legend class="sr-only">Approval</legend>
    {#each CHOICES as choice (choice)}
      <label class="flex min-h-11 cursor-pointer items-center gap-3 text-sm">
        <input type="radio" name="setting" value={choice} bind:group={setting} />
        {approvalSetting(choice)}
      </label>
    {/each}
  </fieldset>
  <div class="mt-3 flex gap-2">
    <Button variant="primary" type="submit" busy={submission.busy() && 'Saving…'}>Save</Button>
    <Button href={href.settings()}>Cancel</Button>
  </div>
</form>
