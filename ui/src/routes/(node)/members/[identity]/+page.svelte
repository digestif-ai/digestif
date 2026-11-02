<script lang="ts">
  import { refreshAll } from '$app/navigation';
  import { createClient } from '#lib/api/client.ts';
  import Button from '#lib/components/Button.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import FeedRow from '#lib/components/FeedRow.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import StatusBadge from '#lib/components/StatusBadge.svelte';
  import { clockTime, memberStage, relativeTime, shortKey, statusNoteWords } from '#lib/format.ts';
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
      () => refreshAll()
    );
  }
</script>

<PageHeader title={member.name} crumbs={[{ label: 'Members', href: href.members() }]}>
  {#snippet actions()}
    {#if member.is_self}
      <Button href={href.phoneNew()}>Add a phone</Button>
    {/if}
    {#if !member.is_self && member.status !== 'revoked'}
      <Button busy={submission.busy() && (member.muted ? 'Unmuting…' : 'Muting…')} onclick={handleMute}
        >{member.muted ? 'Unmute' : 'Mute'}</Button
      >
    {/if}
  {/snippet}
</PageHeader>
<ErrorBanner errors={submission.errors} />

<section class="dg-card p-4">
  <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
    <dt class="dg-muted">Stage</dt>
    <dd>
      <StatusBadge status={member.status === 'revoked' ? { label: 'Revoked', tone: 'bad' } : memberStage(member.stage)} />
    </dd>
    <dt class="dg-muted">Agent</dt>
    <dd>{member.stage === 'onboarding' ? '' : member.agent_name}</dd>
    <dt class="dg-muted">Last note</dt>
    <dd>
      {#if member.last_note_at === undefined}None yet{:else}{clockTime(member.last_note_at)}{#if member.last_status_note}
          · {statusNoteWords(member.last_status_note, member.name)}{/if}{/if}
    </dd>
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
