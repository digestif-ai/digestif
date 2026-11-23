<script lang="ts">
  // Member review (docs/design.md, Member review; DES-376): an item the node's upkeep raised about a
  // member in review. An admin reads who is silent and for how long, with the command that removes
  // them; the member reads that their membership is in review, then Kept, or, once revoked, who
  // removed them. Keep is the page header's.
  import { MessageStatus, type Item, type Member, type SignerSet } from '#generated/ai-digestif-digestif-node.ts';
  import { clockTime, memberStage, noteDate } from '../format.ts';
  import { href } from '../href.ts';
  import { askedLine, IN_REVIEW, removeCommand, reviewLine, type ReviewPage } from '../review.ts';
  import CommandBlock from './CommandBlock.svelte';
  import StatusBadge from './StatusBadge.svelte';

  interface Props {
    page: ReviewPage;
    item: Item;
    member: Member;
    signers: SignerSet | undefined;
    self: string | undefined;
  }

  let { page, item, member, signers, self }: Props = $props();
  const first = $derived(member.name.split(' ')[0]);
  const asked = $derived(askedLine(signers, page === 'admin' ? self : undefined));
  const lastNote = $derived(member.last_note_at === undefined ? 'None yet' : clockTime(member.last_note_at));
  // The member's last notes: what they shared, never a status note.
  const notes = $derived(
    member.recent.filter((m) => m.kind === 'summary' && m.status_note === undefined && m.status === MessageStatus.Posted).slice(0, 3)
  );
</script>

<section class="dg-card p-4" data-testid="review-facts">
  <dl class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1 text-sm">
    {#if page === 'admin'}
      <dt class="dg-muted">Member</dt>
      <dd><a class="dg-link" href={href.member(member.identity)}>{member.name}</a> · {member.agent_name}</dd>
      <dt class="dg-muted">Stage</dt>
      <dd class="flex flex-wrap gap-1">
        <StatusBadge status={memberStage(member.stage)} />{#if member.in_review_since}<StatusBadge status={IN_REVIEW} />{/if}
      </dd>
      <dt class="dg-muted">Last note</dt>
      <dd>{lastNote}</dd>
      {#if member.last_status_note_words && member.last_status_note_at}
        <dt class="dg-muted">Since then</dt>
        <dd>Status note {clockTime(member.last_status_note_at)} · {member.last_status_note_words}</dd>
      {/if}
      <dt class="dg-muted">Joined</dt>
      <dd>{noteDate(member.joined_at)}</dd>
      {#if asked}
        <dt class="dg-muted">Asked</dt>
        <dd>{asked}</dd>
      {/if}
      {#if member.in_review_since}
        <dt class="dg-muted">{first} was told</dt>
        <dd>{clockTime(member.in_review_since)}</dd>
      {:else if member.review}
        <dt class="dg-muted">Review</dt>
        <dd data-testid="review-outcome">{reviewLine(member.review)}</dd>
      {/if}
    {:else if page === 'member'}
      <dt class="dg-muted">Your last note</dt>
      <dd>{lastNote}</dd>
      {#if member.in_review_since}
        <dt class="dg-muted">In review since</dt>
        <dd>{clockTime(member.in_review_since)}</dd>
      {/if}
      {#if asked}
        <dt class="dg-muted">Admins asked</dt>
        <dd>{asked}</dd>
      {/if}
      <dt class="dg-muted">Ends when</dt>
      <dd>Your next note goes out, or an admin keeps or removes you</dd>
    {:else if page === 'kept' && member.review}
      <dt class="dg-muted">Kept by</dt>
      <dd>{member.review.by.name} · admin</dd>
      <dt class="dg-muted">When</dt>
      <dd>{clockTime(member.review.at)}</dd>
      <dt class="dg-muted">Your last note</dt>
      <dd>{lastNote}</dd>
      <dt class="dg-muted">Next</dt>
      <dd>Counted from the Keep's day: in review again after three whole days with no note</dd>
    {:else if page === 'removed' && member.review}
      <dt class="dg-muted">Revoked by</dt>
      <dd>{member.review.by.name}</dd>
      <dt class="dg-muted">When</dt>
      <dd>{clockTime(member.review.at)}</dd>
      <dt class="dg-muted">Your last note</dt>
      <dd>{lastNote}</dd>
      <dt class="dg-muted">Your notes</dt>
      <dd>The circle keeps what it read</dd>
      <dt class="dg-muted">The circle's notes</dt>
      <dd>Readable on this machine up to {clockTime(member.review.at)}</dd>
      <dt class="dg-muted">To return</dt>
      <dd>A new invite from the admins</dd>
    {/if}
  </dl>
</section>

{#if page === 'admin' && member.in_review_since && item.done === undefined}
  <div class="mt-4"><CommandBlock label="Remove" command={removeCommand(member.identity)} /></div>
{/if}

{#if page === 'admin' && notes.length > 0}
  <h2 class="dg-label mt-6 mb-2">{first}'s last notes</h2>
  <ul class="dg-card dg-rows overflow-hidden">
    {#each notes as note (note.hash)}
      <li class="flex items-baseline gap-3 px-4 py-3 text-sm">
        <a class="dg-link min-w-0 truncate" href={href.message(note.hash)}>{note.preview}</a>
        <span class="dg-muted ml-auto text-xs whitespace-nowrap">{noteDate(note.created_at)}</span>
      </li>
    {/each}
  </ul>
{/if}
