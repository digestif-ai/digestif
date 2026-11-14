<script lang="ts">
  import { goto } from '$app/navigation';
  import { Stage, type Item } from '#generated/ai-digestif-digestif-node.ts';
  import { createClient } from '#lib/api/client.ts';
  import Button from '#lib/components/Button.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import { href } from '#lib/href.ts';
  import { NEW_ITEM_KINDS, newItemForm, type NewItemKind } from '#lib/items.ts';
  import { Submission } from '#lib/submission.svelte.ts';
  import type { PageData } from './$types';

  // New item (DES-51007, The New item page): a question, a notice, an intro or a prompt suggestion.
  // The fields follow the kind; Save draft keeps it in the member's Inbox, Send delivers it.
  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const self = $derived(data.members.find((m) => m.is_self));
  const others = $derived(data.members.filter((m) => !m.is_self && m.stage !== Stage.Onboarding));

  let kind = $state<NewItemKind>('question');
  let circle = $state(true);
  let named = $state<string[]>([]);
  let title = $state('');
  let detail = $state('');

  /** A question and a notice offer The circle or Named members; an intro and a suggestion name members. */
  const offersCircle = $derived(kind === 'question' || kind === 'notice');
  const namesMembers = $derived(!offersCircle || !circle);
  const membersLabel = $derived(
    kind === 'intro' ? 'The two people it introduces' : kind === 'suggestion' ? 'Judges, you among them' : 'Members'
  );

  const client = createClient();
  const submission = new Submission();

  async function submit(send: boolean): Promise<void> {
    const form = newItemForm({ kind, circle, members: named, title, detail, send }, self?.identity);
    await submission.run(
      () => client.createItem(form),
      (item: Item) => goto(href.item(item.id), { invalidateAll: true }),
      send ? 'send' : 'draft'
    );
  }

  const KIND_LABEL: Record<NewItemKind, string> = {
    question: 'Question',
    notice: 'Notice',
    intro: 'Intro',
    suggestion: 'Prompt suggestion'
  };
</script>

<PageHeader title="New item" crumbs={[{ label: 'Inbox', href: href.inbox() }]} />

<form
  class="dg-card p-4"
  aria-label="New item"
  onsubmit={(e) => {
    e.preventDefault();
    void submit(true);
  }}
>
  <ErrorBanner errors={submission.generalErrors(['title', 'members'])} />
  <label class="mb-4 block">
    <span class="dg-label mb-1 block">Kind</span>
    <select class="dg-input" bind:value={kind}>
      {#each NEW_ITEM_KINDS as k (k)}<option value={k}>{KIND_LABEL[k]}</option>{/each}
    </select>
  </label>

  <fieldset class="mb-4">
    <legend class="dg-label mb-1">To</legend>
    {#if offersCircle}
      <div class="flex flex-wrap gap-4 text-sm">
        <label class="flex min-h-11 items-center gap-2"><input type="radio" name="to" value={true} bind:group={circle} /> The circle</label>
        <label class="flex min-h-11 items-center gap-2"
          ><input type="radio" name="to" value={false} bind:group={circle} /> Named members</label
        >
      </div>
    {/if}
    {#if namesMembers}
      <div role="group" aria-label={membersLabel} class="mt-1">
        {#if !offersCircle}<p class="dg-muted mb-1 text-xs">{membersLabel}</p>{/if}
        <div class="flex flex-wrap gap-x-4 text-sm">
          {#each others as m (m.identity)}
            <label class="flex min-h-11 items-center gap-2"><input type="checkbox" value={m.identity} bind:group={named} /> {m.name}</label>
          {/each}
        </div>
      </div>
      {#if submission.fieldError('members')}<p class="mt-1 text-sm text-red-700 dark:text-red-300">
          {submission.fieldError('members')}
        </p>{/if}
    {/if}
  </fieldset>

  <label class="mb-4 block">
    <span class="dg-label mb-1 block">Title</span>
    <input class="dg-input" type="text" bind:value={title} />
    {#if submission.fieldError('title')}<span class="mt-1 block text-sm text-red-700 dark:text-red-300"
        >{submission.fieldError('title')}</span
      >{/if}
  </label>
  <label class="mb-4 block">
    <span class="dg-label mb-1 block">Detail</span>
    <textarea class="dg-input min-h-32" bind:value={detail}></textarea>
  </label>

  <div class="flex flex-wrap justify-end gap-2">
    <Button href={href.inbox()}>Cancel</Button>
    <Button busy={submission.pending('draft') && 'Saving…'} disabled={submission.busy()} onclick={() => submit(false)}>Save draft</Button>
    <Button variant="primary" type="submit" busy={submission.pending('send') && 'Sending…'} disabled={submission.busy()}>Send</Button>
  </div>
</form>
