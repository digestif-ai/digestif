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
  let text = $state(data.prompt.text);
  // svelte-ignore state_referenced_locally
  let adoptPractices = $state(data.prompt.adopt_practices);
  // svelte-ignore state_referenced_locally
  let practices = $state(data.prompt.practices);

  const client = createClient();
  const submission = new Submission();
  const removal = new Submission();

  async function handleSubmit(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    await submission.run(
      () => client.saveInboxAgent(text, adoptPractices),
      () => goto(href.inboxAgent(), { refreshAll: true })
    );
  }

  async function remove(id: string): Promise<void> {
    await removal.run(
      () => client.removeInboxPractice(id),
      (saved) => {
        practices = saved.practices;
      },
      id
    );
  }
</script>

<PageHeader
  title="Edit the Inbox prompt"
  crumbs={[
    { label: 'Settings', href: href.settings() },
    { label: 'Inbox agent', href: href.inboxAgent() }
  ]}
/>

<form class="dg-card p-4" onsubmit={handleSubmit}>
  <ErrorBanner errors={submission.generalErrors(['text'])} />
  <label class="dg-label mb-1 block" for="inbox-prompt">Inbox prompt</label>
  <textarea id="inbox-prompt" class="dg-input min-h-60" bind:value={text}></textarea>
  {#if submission.fieldError('text')}<p class="mt-1 text-sm text-red-700 dark:text-red-300">{submission.fieldError('text')}</p>{/if}
  <label class="mt-3 flex items-center gap-2 text-sm">
    <input type="checkbox" bind:checked={adoptPractices} />
    Adopt a practice I see working for another agent in the circle on my own
  </label>
  <div class="mt-3 flex gap-2">
    <Button href={href.inboxAgent()}>Cancel</Button>
    <Button variant="primary" type="submit" busy={submission.busy() && 'Saving…'}>Save</Button>
  </div>
</form>

{#if practices.length > 0}
  <h2 class="mt-6 mb-2 text-sm font-semibold">Adopted practices</h2>
  <ErrorBanner errors={removal.errors} />
  <ul class="dg-card divide-y text-sm" data-testid="inbox-agent-practices">
    {#each practices as practice (practice.id)}
      <li class="flex items-start justify-between gap-3 p-3">
        <div>
          <p>{practice.text}</p>
          <p class="dg-muted mt-1">From {practice.author.name}</p>
        </div>
        <Button onclick={() => remove(practice.id)} disabled={removal.busy()} busy={removal.pending(practice.id) && 'Removing…'}
          >Remove</Button
        >
      </li>
    {/each}
  </ul>
{/if}
