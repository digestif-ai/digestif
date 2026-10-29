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
  const back = $derived(data.self === undefined ? href.members() : href.member(data.self.identity));

  let code = $state('');
  let phrase = $state('');

  const client = createClient();
  const submission = new Submission();
  const FIELDS = ['pairing_code', 'recovery_phrase'];

  async function handleSubmit(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    await submission.run(
      () => client.addPhone({ pairing_code: code, recovery_phrase: phrase }),
      async () => {
        phrase = '';
        await goto(back, { refreshAll: true });
      }
    );
  }
</script>

<PageHeader
  title="Add a phone"
  crumbs={[{ label: 'Members', href: href.members() }, ...(data.self === undefined ? [] : [{ label: data.self.name, href: back }])]}
/>

<form class="dg-card p-4" onsubmit={handleSubmit}>
  <ErrorBanner errors={submission.generalErrors(FIELDS)} />
  <label class="dg-label mb-1 block" for="pairing-code">Pairing code</label>
  <input id="pairing-code" class="dg-input font-mono text-xs" autocomplete="off" spellcheck="false" bind:value={code} />
  {#if submission.fieldError('pairing_code')}
    <p class="mt-1 text-sm text-red-700 dark:text-red-300">{submission.fieldError('pairing_code')}</p>
  {/if}

  <label class="dg-label mt-4 mb-1 block" for="recovery-phrase">Recovery phrase</label>
  <textarea id="recovery-phrase" class="dg-input min-h-24" autocomplete="off" spellcheck="false" bind:value={phrase}></textarea>
  {#if submission.fieldError('recovery_phrase')}
    <p class="mt-1 text-sm text-red-700 dark:text-red-300">{submission.fieldError('recovery_phrase')}</p>
  {/if}

  <div class="mt-3 flex gap-2">
    <Button variant="primary" type="submit" busy={submission.busy() && 'Adding…'}>Add phone</Button>
    <Button href={back}>Cancel</Button>
  </div>
</form>
