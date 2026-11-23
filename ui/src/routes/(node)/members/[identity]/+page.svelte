<script lang="ts">
  import { goto, refreshAll } from '$app/navigation';
  import { CircleApprovalKind, type CircleApproval } from '#generated/ai-digestif-digestif-node.ts';
  import { canRemoveAdmin, isAdmin } from '#lib/approvals.ts';
  import { createClient } from '#lib/api/client.ts';
  import Button from '#lib/components/Button.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import FeedRow from '#lib/components/FeedRow.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import StatusBadge from '#lib/components/StatusBadge.svelte';
  import { clockTime, memberRowStage, relativeTime, shortKey } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import { Submission } from '#lib/submission.svelte.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const member = $derived(data.member);

  const client = createClient();
  const submission = new Submission();

  async function handleMute(): Promise<void> {
    await submission.run(
      () => client.mute(member.identity, !member.muted),
      () => refreshAll(),
      'mute'
    );
  }

  // DES-85466, member-detail: an admin promotes a member, or removes an admin to member while the set
  // keeps two keys after it; either files the approval and opens its Inbox item, where every admin signs.
  const signers = $derived('data' in data.signers ? data.signers.data : undefined);
  const viewerAdmin = $derived(isAdmin(data.self));
  const canPromote = $derived(
    viewerAdmin && signers !== undefined && !signers.halted && !isAdmin(member) && !member.is_self && member.status !== 'revoked'
  );
  const canRemove = $derived(viewerAdmin && signers !== undefined && isAdmin(member) && canRemoveAdmin(signers));

  async function start(kind: CircleApprovalKind.Promotion | CircleApprovalKind.Removal): Promise<void> {
    await submission.run(
      () => client.startApproval({ kind, member: member.identity }),
      (a: CircleApproval) => (a.item === undefined ? refreshAll() : goto(href.item(a.item), { invalidateAll: true })),
      kind
    );
  }
</script>

<PageHeader title={member.name} crumbs={[{ label: 'Members', href: href.members() }]}>
  {#snippet actions()}
    {#if canPromote}
      <Button
        busy={submission.pending(CircleApprovalKind.Promotion) && 'Asking…'}
        disabled={submission.busy()}
        onclick={() => start(CircleApprovalKind.Promotion)}>Promote to Admin</Button
      >
    {:else if canRemove}
      <Button
        busy={submission.pending(CircleApprovalKind.Removal) && 'Asking…'}
        disabled={submission.busy()}
        onclick={() => start(CircleApprovalKind.Removal)}>Remove as Admin</Button
      >
    {/if}
    {#if !member.is_self && member.status !== 'revoked'}
      <Button
        busy={submission.pending('mute') && (member.muted ? 'Unmuting…' : 'Muting…')}
        disabled={submission.busy()}
        onclick={handleMute}>{member.muted ? 'Unmute' : 'Mute'}</Button
      >
    {/if}
  {/snippet}
</PageHeader>
<ErrorBanner errors={submission.errors} />

<section class="dg-card p-4">
  <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
    <dt class="dg-muted">Stage</dt>
    <dd>
      <StatusBadge status={memberRowStage(member)} />
    </dd>
    <dt class="dg-muted">Role</dt>
    <dd data-testid="member-role">{isAdmin(member) ? 'Admin' : 'Member'}</dd>
    <dt class="dg-muted">Agent</dt>
    <dd>{member.stage === 'onboarding' ? '' : member.agent_name}</dd>
    <dt class="dg-muted">Last note</dt>
    <dd>
      {#if member.last_note_at === undefined}None yet{:else}{clockTime(member.last_note_at)}{/if}
    </dd>
    {#if member.last_status_note_words && member.last_status_note_at}
      <dt class="dg-muted">Status note</dt>
      <dd>{clockTime(member.last_status_note_at)} · {member.last_status_note_words}</dd>
    {/if}
    <dt class="dg-muted">Notes</dt>
    <dd>{member.muted ? 'Muted: filtered before your agent reads them' : 'Read by your agent'}</dd>
    <dt class="dg-muted">Joined</dt>
    <dd>{relativeTime(member.joined_at)}</dd>
    <dt class="dg-muted">Identity</dt>
    <dd class="font-mono text-xs break-all">{member.identity}</dd>
  </dl>
</section>

<h2 class="dg-label mt-6 mb-2">Devices</h2>
<ul class="dg-card dg-rows overflow-hidden">
  {#each member.devices as device (device.key)}
    <li class="flex min-h-11 items-center gap-3 px-4 py-3 text-sm">
      <span class="font-mono text-xs">{shortKey(device.key)}</span>
      <span class="dg-muted">{device.role} · admitted {relativeTime(device.admitted_at)}</span>
      {#if device.revoked_at}<span class="ml-auto"><StatusBadge status={{ label: 'Revoked', tone: 'bad' }} /></span>{/if}
    </li>
  {/each}
</ul>

<h2 class="dg-label mt-6 mb-2">Recent</h2>
<ul class="dg-card dg-rows overflow-hidden">
  {#each member.recent as item (item.hash)}
    <FeedRow {item} href={href.message(item.hash)} />
  {:else}
    <li class="dg-muted px-4 py-6 text-center text-sm">Nothing yet</li>
  {/each}
</ul>
