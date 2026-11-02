<script lang="ts">
  import { createClient } from '#lib/api/client.ts';
  import Button from '#lib/components/Button.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import QrCode from '#lib/components/QrCode.svelte';
  import { href } from '#lib/href.ts';
  import { checkPairingCode, type CodeCheck } from '#lib/pairing.ts';
  import { Submission } from '#lib/submission.svelte.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const back = href.phones();
  const appUrl = $derived(data.status.phone_app_url);

  const client = createClient();
  const submission = new Submission();
  const FIELDS = ['pairing_code', 'recovery_phrase'];

  let code = $state('');
  let phrase = $state('');
  let check = $state<CodeCheck>({ state: 'empty' });
  let added = $state(false);

  // The check runs as the code is typed; a slower answer for an older value is dropped.
  $effect(() => {
    const typed = code;
    let live = true;
    void checkPairingCode(typed).then((r) => {
      if (live) check = r;
    });
    return () => {
      live = false;
    };
  });

  /** Whose turn it is: open the app, then paste its code, then sign. */
  const step = $derived(check.state === 'ok' ? 3 : code.trim() === '' ? 1 : 2);
  const codeMessage = $derived(check.state === 'mistyped' ? check.message : submission.fieldError('pairing_code'));

  async function handleSubmit(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    await submission.run(
      () => client.addPhone({ pairing_code: code, recovery_phrase: phrase }),
      () => {
        phrase = '';
        added = true;
      }
    );
  }

  const card = (n: number): string => 'dg-card p-4 ' + (step === n ? 'border-dg-accent dark:border-pink-300' : '');
</script>

<PageHeader
  title="Add a phone"
  crumbs={[
    { label: 'Settings', href: href.settings() },
    { label: 'Phones', href: back }
  ]}
/>

{#if added}
  <section class="dg-card p-4" data-testid="phone-added">
    <p role="status">Phone added. It finishes setting itself up on its next sync.</p>
    <div class="mt-3">
      <Button variant="primary" href={back}>Done</Button>
    </div>
  </section>
{:else}
  <form onsubmit={handleSubmit}>
    <ErrorBanner errors={submission.generalErrors(FIELDS)} />
    <ol class="space-y-3">
      <li class={card(1)} data-testid="phone-step-1">
        <h2 class="font-semibold">1. Open the phone app</h2>
        {#if appUrl === undefined}
          <p class="mt-1 text-sm">No relay in your circle serves the phone app yet.</p>
        {:else}
          <p class="mt-1 text-sm">Open this on your phone; it shows a pairing code.</p>
          <div class="mt-3 flex flex-col items-start gap-3 sm:flex-row sm:items-center">
            <QrCode value={appUrl} label="QR code for the phone app" />
            <a class="dg-link font-mono text-sm break-all" href={appUrl} target="_blank" rel="noopener noreferrer">{appUrl}</a>
          </div>
        {/if}
      </li>

      <li class={card(2)} data-testid="phone-step-2">
        <h2 class="font-semibold"><label for="pairing-code">2. Pairing code</label></h2>
        <p class="mt-1 text-sm">Paste the code your phone shows.</p>
        <input
          id="pairing-code"
          class="dg-input mt-2 font-mono text-xs"
          autocomplete="off"
          autocapitalize="off"
          spellcheck="false"
          placeholder="p1."
          bind:value={code}
        />
        {#if codeMessage}
          <p class="mt-1 text-sm text-red-700 dark:text-red-300" data-testid="code-check">{codeMessage}</p>
        {:else if check.state === 'ok'}
          <p class="mt-1 text-sm text-green-700 dark:text-green-300" data-testid="code-check">The code checks out.</p>
        {/if}
      </li>

      <li class={card(3)} data-testid="phone-step-3">
        <h2 class="font-semibold"><label for="recovery-phrase">3. Recovery phrase</label></h2>
        <p class="mt-1 text-sm">Your 24 words sign the phone's admission once; the node does not store them.</p>
        <textarea
          id="recovery-phrase"
          class="dg-input mt-2 min-h-24"
          autocomplete="off"
          autocapitalize="off"
          spellcheck="false"
          bind:value={phrase}></textarea>
        {#if submission.fieldError('recovery_phrase')}
          <p class="mt-1 text-sm text-red-700 dark:text-red-300">{submission.fieldError('recovery_phrase')}</p>
        {/if}
        <div class="mt-3 flex flex-wrap gap-2">
          <Button variant="primary" type="submit" busy={submission.busy() && 'Adding…'}>Add phone</Button>
          <Button href={back}>Cancel</Button>
        </div>
      </li>
    </ol>
  </form>
{/if}
