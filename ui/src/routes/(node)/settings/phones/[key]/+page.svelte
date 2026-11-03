<script lang="ts">
  import { invalidateAll } from '$app/navigation';
  import { createClient } from '#lib/api/client.ts';
  import Button from '#lib/components/Button.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import StatusBadge from '#lib/components/StatusBadge.svelte';
  import { relativeTime, shortKey } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import { Submission } from '#lib/submission.svelte.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const phone = $derived(data.phone);

  const client = createClient();
  const submission = new Submission();
  let removing = $state(false);
  let phrase = $state('');

  async function handleSubmit(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    await submission.run(
      () => client.revokePhone(phone.key, phrase),
      async () => {
        phrase = '';
        removing = false;
        await invalidateAll();
      }
    );
  }
</script>

<PageHeader
  title={'Phone ' + shortKey(phone.key)}
  crumbs={[
    { label: 'Settings', href: href.settings() },
    { label: 'Phones', href: href.phones() }
  ]}
>
  {#snippet actions()}
    {#if phone.revoked_at === undefined && !removing}
      <Button variant="danger" onclick={() => (removing = true)}>Remove</Button>
    {/if}
  {/snippet}
</PageHeader>

<section class="dg-card p-4">
  <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
    <dt class="dg-muted">Status</dt>
    <dd>
      {#if phone.revoked_at}<StatusBadge status={{ label: 'Removed', tone: 'bad' }} />{:else}<StatusBadge
          status={{ label: 'Active', tone: 'good' }}
        />{/if}
    </dd>
    <dt class="dg-muted">Added</dt>
    <dd>{relativeTime(phone.admitted_at)}</dd>
    {#if phone.revoked_at}
      <dt class="dg-muted">Removed</dt>
      <dd>{relativeTime(phone.revoked_at)}</dd>
    {/if}
    <dt class="dg-muted">Key</dt>
    <dd class="font-mono text-xs break-all">{phone.key}</dd>
  </dl>
</section>

{#if removing}
  <form class="dg-card mt-4 p-4" onsubmit={handleSubmit} data-testid="phone-remove">
    <ErrorBanner errors={submission.generalErrors(['recovery_phrase'])} />
    <label class="block">
      <span class="dg-label mb-1 block">Recovery phrase</span>
      <textarea class="dg-input min-h-24" autocomplete="off" autocapitalize="off" spellcheck="false" bind:value={phrase}></textarea>
    </label>
    {#if submission.fieldError('recovery_phrase')}
      <p class="mt-1 text-sm text-red-700 dark:text-red-300">{submission.fieldError('recovery_phrase')}</p>
    {/if}
    <div class="mt-3 flex flex-wrap gap-2">
      <Button variant="danger" type="submit" busy={submission.busy() && 'Removing…'}>Remove phone</Button>
      <Button onclick={() => (removing = false)} disabled={submission.busy()}>Cancel</Button>
    </div>
  </form>
{/if}
