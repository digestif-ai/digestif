<script lang="ts">
  import { goto, invalidateAll } from '$app/navigation';
  import { ItemDone, ItemKind, ItemStatus, ItemSubject, Voice, type Item } from '#generated/com-bryzek-digestif-node.ts';
  import { createClient } from '#lib/api/client.ts';
  import ActionMenu from '#lib/components/ActionMenu.svelte';
  import Button from '#lib/components/Button.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import StatusBadge from '#lib/components/StatusBadge.svelte';
  import { relativeTime } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import { answerer, closedOn, itemActions, itemFrom, itemKind, itemStatus, itemTo, reviewParts } from '#lib/items.ts';
  import { Submission } from '#lib/submission.svelte.ts';
  import type { PageData } from './$types';

  // One item (DES-51007): what it says, then what the reader does with it. A draft is sent, edited in
  // place or discarded; a question is answered or set aside with Not for me, and its asker closes it
  // naming the answer that unblocked them; a choice is picked; a notice is acknowledged.
  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const item = $derived(data.item);
  const self = $derived(data.self);
  const can = $derived(itemActions(item, self));
  const agentName = $derived(data.status.agent_name ?? 'Your agent');
  const unblocked = $derived(closedOn(item));

  const client = createClient();
  const submission = new Submission();

  /** Opening an item makes it Read: once the page shows it, never on a hover's preload. */
  let opened = '';
  $effect(() => {
    if (item.status !== ItemStatus.New || opened === item.id) return;
    opened = item.id;
    void client.readItem(item.id).then(() => invalidateAll());
  });

  type Mode = 'view' | 'edit' | 'discard' | 'name';
  let mode = $state<Mode>('view');
  let title = $state('');
  let detail = $state('');
  let answer = $state('');

  function startEdit(): void {
    title = item.title;
    detail = item.detail;
    mode = 'edit';
  }

  async function act(key: string, request: () => ReturnType<typeof client.item>): Promise<void> {
    await submission.run(
      request,
      async () => {
        mode = 'view';
        await invalidateAll();
      },
      key
    );
  }

  const save = (): Promise<void> => act('save', () => client.editItem(item.id, { title, detail }));
  const send = (): Promise<void> => act('send', () => client.sendItem(item.id));
  const pick = (id: string): Promise<void> => act('pick-' + id, () => client.pickItem(item.id, id));
  const acknowledge = (): Promise<void> => act('acknowledge', () => client.acknowledgeItem(item.id));
  const notForMe = (): Promise<void> => act('not-for-me', () => client.notForMe(item.id));
  const close = (closed: boolean, on?: string): Promise<void> =>
    act('close-' + (on ?? String(closed)), () => client.closeItem(item.id, on === undefined ? { closed } : { closed, answer: on }));

  async function handleAnswer(): Promise<void> {
    await submission.run(
      () => client.answerItem(item.id, answer),
      async () => {
        answer = '';
        await invalidateAll();
      },
      'answer'
    );
  }

  async function discard(): Promise<void> {
    await submission.run(
      () => client.discardItem(item.id),
      () => goto(href.inbox(), { invalidateAll: true }),
      'discard'
    );
  }

  const menu = $derived.by(() => {
    const actions: { label: string; onselect: () => void }[] = [];
    if (mode !== 'view') return actions;
    if (can.draft) actions.push({ label: 'Edit', onselect: startEdit }, { label: 'Discard', onselect: () => (mode = 'discard') });
    if (can.notForMe) actions.push({ label: 'Not for me', onselect: () => void notForMe() });
    if (can.close) {
      if (item.answers.length > 0)
        actions.push({ label: item.closed ? 'Name a different answer' : 'Close on an answer', onselect: () => (mode = 'name') });
      actions.push(
        item.closed ? { label: 'Reopen', onselect: () => void close(false) } : { label: 'Close', onselect: () => void close(true) }
      );
    }
    return actions;
  });

  const DONE: Record<ItemDone, string> = {
    [ItemDone.Answered]: 'You answered it.',
    [ItemDone.Picked]: 'You picked.',
    [ItemDone.Acknowledged]: 'You acknowledged it.',
    [ItemDone.NotForMe]: 'You set it aside: not for you.',
    [ItemDone.Closed]: 'It is closed.'
  };

  /** "by Hermes, 2d ago, on Ben Ortiz's answer". */
  function closeLine(c: NonNullable<Item['close']>): string {
    const by = c.voice === Voice.Agent ? agentName : 'you';
    const on = c.answer === undefined ? undefined : item.answers.find((a) => a.hash === c.answer);
    return 'by ' + by + ', ' + relativeTime(c.at) + (on === undefined ? '' : ', on ' + answerer(on, self).name + "'s answer");
  }
  /** The agent's close a person's overruled, kept beside it. */
  const overruled = $derived(
    item.close?.voice === Voice.Person ? item.closes.find((c) => c !== item.close && c.closed && c.voice === Voice.Agent) : undefined
  );

  const optionLabel = (id: string | undefined): string | undefined => item.options.find((o) => o.id === id)?.label;
  const myPick = $derived(item.picks.find((p) => p.member.identity === self));
  const options = $derived([...item.options].sort((a, b) => Number(b.recommended) - Number(a.recommended)));

  /** Where a node's own item is acted on. */
  const PATH_LABEL: Partial<Record<ItemSubject, string>> = {
    [ItemSubject.Repositories]: 'Choose on Settings, Repositories',
    [ItemSubject.NoteReady]: 'Open the waiting note',
    [ItemSubject.PauseComing]: 'Open the waiting note',
    [ItemSubject.Suggestion]: "Pick tonight's version on your waiting note"
  };
  const pathLabel = $derived((item.subject === undefined ? undefined : PATH_LABEL[item.subject]) ?? 'Open it');
  const reviewHeading = $derived(item.status === ItemStatus.Draft ? 'Why ' + agentName + ' drafted it' : agentName + "'s review");
</script>

<PageHeader title={item.title} crumbs={[{ label: 'Inbox', href: href.inbox() }]}>
  {#snippet actions()}
    <ActionMenu actions={menu} disabled={submission.busy()} />
  {/snippet}
</PageHeader>

<p class="dg-muted -mt-2 mb-4 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs" data-testid="item-subline">
  <StatusBadge status={itemStatus(item.status)} />
  <span>{itemKind(item)}</span>
  <span>{itemFrom(item, self)}</span>
  <span>{itemTo(item, self)}</span>
  <span>{relativeTime(item.created_at)}</span>
  {#if item.reviewed_at}<span>reviewed {relativeTime(item.reviewed_at)}</span>{/if}
</p>

<ErrorBanner errors={submission.errors} />

{#if mode === 'edit'}
  <form
    class="dg-card p-4"
    aria-label="Edit the draft"
    onsubmit={(e) => {
      e.preventDefault();
      void save();
    }}
  >
    <label class="mb-4 block">
      <span class="dg-label mb-1 block">Title</span>
      <input class="dg-input" type="text" bind:value={title} />
    </label>
    <label class="mb-4 block">
      <span class="dg-label mb-1 block">Detail</span>
      <textarea class="dg-input min-h-40" bind:value={detail}></textarea>
    </label>
    <div class="flex flex-wrap justify-end gap-2">
      <Button disabled={submission.busy()} onclick={() => (mode = 'view')}>Cancel</Button>
      <Button variant="primary" type="submit" busy={submission.pending('save') && 'Saving…'} disabled={submission.busy()}>Save</Button>
    </div>
  </form>
{:else}
  <article class="dg-card p-4">
    <p class="text-sm whitespace-pre-wrap" data-testid="item-detail">{item.detail}</p>
    {#if item.closed || item.about || item.deadline_at}
      <dl class="mt-3 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
        {#if item.close?.closed}
          <dt class="dg-muted">Closed</dt>
          <dd data-testid="item-closed">{closeLine(item.close)}</dd>
        {/if}
        {#if overruled}
          <dt class="dg-muted">{agentName} closed it</dt>
          <dd data-testid="item-agent-close">{closeLine(overruled)}</dd>
        {/if}
        {#if item.deadline_at && !item.closed}
          <dt class="dg-muted">Deadline</dt>
          <dd>
            {relativeTime(item.deadline_at)}{#if optionLabel(item.default_option)}, then {optionLabel(item.default_option)}{/if}
          </dd>
        {/if}
        {#if item.about}
          <dt class="dg-muted">From</dt>
          <dd><a class="dg-link" href={href.message(item.about)}>the message it came from</a></dd>
        {/if}
      </dl>
    {/if}
  </article>
{/if}

{#if item.drafted}
  <h2 class="dg-label mt-6 mb-2">{agentName}'s words</h2>
  <div class="dg-card p-4" data-testid="item-drafted">
    <p class="mb-2 text-sm font-medium">{item.drafted.title}</p>
    <p class="dg-muted text-sm whitespace-pre-wrap">{item.drafted.detail}</p>
  </div>
{/if}

{#if item.kind === ItemKind.Question && !can.draft}
  <h2 class="dg-label mt-6 mb-2">Answers · {item.answers.length}</h2>
  <ul class="dg-card dg-rows" aria-label="Answers">
    {#each item.answers as a (a.hash)}
      {@const who = answerer(a, self)}
      <li class="px-4 py-3" data-testid="item-answer">
        <p class="dg-muted mb-1 flex flex-wrap items-center gap-2 text-xs">
          <span class="font-medium text-stone-900 dark:text-stone-100">{who.name}</span>
          <span class="rounded border border-stone-200 px-1 dark:border-stone-700">{who.voice}</span>
          <span>{relativeTime(a.created_at)}</span>
          {#if unblocked?.hash === a.hash}<span>· unblocked it</span>{/if}
        </p>
        <p class="text-sm whitespace-pre-wrap">{a.text}</p>
        {#if mode === 'name' && unblocked?.hash !== a.hash}
          <div class="mt-2">
            <Button
              busy={submission.pending('close-' + a.hash) && 'Closing…'}
              disabled={submission.busy()}
              onclick={() => close(true, a.hash)}>This unblocked it</Button
            >
          </div>
        {/if}
      </li>
    {:else}
      <li class="dg-muted px-4 py-6 text-center text-sm">No answers yet</li>
    {/each}
  </ul>
  {#if mode === 'name'}
    <div class="mt-2"><Button disabled={submission.busy()} onclick={() => (mode = 'view')}>Cancel</Button></div>
  {/if}
{/if}

{#if item.review}
  <h2 class="dg-label mt-6 mb-2">{reviewHeading}</h2>
  <div class="dg-card p-4">
    <p class="text-sm" data-testid="item-review">
      {#each reviewParts(item.review) as part, i (i)}{#if 'href' in part}<a class="dg-link" href={part.href} rel="noopener noreferrer"
            >{part.text}</a
          >{:else}{part.text}{/if}{/each}
    </p>
  </div>
{/if}

{#if item.status === ItemStatus.Done && item.done !== undefined && item.done !== ItemDone.Closed}
  <p class="dg-muted mt-4 text-sm" data-testid="item-done">
    {DONE[item.done]}{#if myPick}&nbsp;{optionLabel(myPick.option_id)}, {relativeTime(myPick.picked_at)}.{/if}
  </p>
{/if}

{#if mode === 'discard'}
  <div class="mt-6 border-t border-stone-200 pt-4 dark:border-stone-800">
    <p class="mb-2 text-sm">Discard this draft? Nothing was sent.</p>
    <div class="flex gap-2">
      <Button variant="danger" busy={submission.pending('discard') && 'Discarding…'} disabled={submission.busy()} onclick={discard}
        >Discard</Button
      >
      <Button disabled={submission.busy()} onclick={() => (mode = 'view')}>Cancel</Button>
    </div>
  </div>
{:else if mode === 'view'}
  {#if item.path}
    <p class="mt-4 text-sm"><a class="dg-link" href={item.path} data-testid="item-path">{pathLabel}</a></p>
  {/if}
  {#if can.draft}
    <div class="mt-4 flex flex-wrap gap-2">
      <Button variant="primary" busy={submission.pending('send') && 'Sending…'} disabled={submission.busy()} onclick={send}>Send</Button>
    </div>
  {:else if can.pick && item.subject !== ItemSubject.Suggestion}
    <div class="mt-4 flex flex-wrap gap-2">
      {#each options as option (option.id)}
        <Button
          variant={option.recommended ? 'primary' : 'secondary'}
          busy={submission.pending('pick-' + option.id) && 'Picking…'}
          disabled={submission.busy()}
          onclick={() => pick(option.id)}>{option.label}</Button
        >
      {/each}
    </div>
  {:else if can.acknowledge}
    <div class="mt-4">
      <Button
        variant="primary"
        busy={submission.pending('acknowledge') && 'Acknowledging…'}
        disabled={submission.busy()}
        onclick={acknowledge}>Acknowledge</Button
      >
    </div>
  {/if}
  {#if can.answer}
    <form
      class="mt-6"
      aria-label="Answer the question"
      onsubmit={(e) => {
        e.preventDefault();
        void handleAnswer();
      }}
    >
      <label class="dg-label mb-2 block" for="item-answer">Your answer</label>
      <div class="dg-card p-4">
        <textarea id="item-answer" class="dg-input min-h-24" bind:value={answer}></textarea>
        <div class="mt-3 flex justify-end">
          <Button variant="primary" type="submit" busy={submission.pending('answer') && 'Answering…'} disabled={submission.busy()}
            >Answer</Button
          >
        </div>
      </div>
    </form>
  {/if}
{/if}
