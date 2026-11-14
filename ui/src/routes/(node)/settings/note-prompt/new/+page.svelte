<script lang="ts">
  import { goto } from '$app/navigation';
  import type { Suggestion } from '#generated/ai-digestif-digestif-node.ts';
  import { createClient } from '#lib/api/client.ts';
  import Button from '#lib/components/Button.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import { href } from '#lib/href.ts';
  import { releasePrompt } from '#lib/note-prompt.ts';
  import { Submission } from '#lib/submission.svelte.ts';
  import type { PageData } from './$types';

  // Suggest a change to the nightly note prompt (ISS-51009): the whole prompt, one line saying what it
  // changes, and the members who judge it beside its author.
  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  // svelte-ignore state_referenced_locally
  let text = $state(data.notePrompt.text ?? releasePrompt);
  let change = $state('');
  let judges = $state<string[]>([]);
  const others = $derived(data.members.filter((m) => !m.is_self));

  const client = createClient();
  const submission = new Submission();

  async function handleSubmit(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    await submission.run(
      () => client.suggestPrompt({ text, change, judges }),
      (s: Suggestion) => goto(href.promptSuggestion(s.hash), { refreshAll: true })
    );
  }
</script>

<PageHeader
  title="Suggest a change"
  crumbs={[
    { label: 'Settings', href: href.settings() },
    { label: 'Note prompt', href: href.notePrompt() }
  ]}
/>

<form class="dg-card p-4" onsubmit={handleSubmit} aria-label="Suggest a change to the note prompt">
  <ErrorBanner errors={submission.generalErrors(['text', 'change', 'judges'])} />
  <label class="dg-label mb-1 block" for="change">What it changes</label>
  <input id="change" class="dg-input mb-1" bind:value={change} />
  {#if submission.fieldError('change')}<p class="mb-1 text-sm text-red-700 dark:text-red-300">{submission.fieldError('change')}</p>{/if}

  <label class="dg-label mt-3 mb-1 block" for="prompt-text">Prompt</label>
  <textarea id="prompt-text" class="dg-input min-h-80 font-mono text-xs" bind:value={text}></textarea>
  {#if submission.fieldError('text')}<p class="mt-1 text-sm text-red-700 dark:text-red-300">{submission.fieldError('text')}</p>{/if}

  <fieldset class="mt-3">
    <legend class="dg-label mb-1">Judges</legend>
    <p class="mb-1 text-sm">You</p>
    {#each others as m (m.identity)}
      <label class="flex min-h-11 items-center gap-2 text-sm">
        <input type="checkbox" value={m.identity} bind:group={judges} />
        {m.name}
      </label>
    {/each}
    {#if submission.fieldError('judges')}<p class="mt-1 text-sm text-red-700 dark:text-red-300">{submission.fieldError('judges')}</p>{/if}
  </fieldset>

  <div class="mt-4 flex gap-2">
    <Button variant="primary" type="submit" busy={submission.busy() && 'Suggesting…'}>Suggest</Button>
    <Button href={href.notePrompt()}>Cancel</Button>
  </div>
</form>
