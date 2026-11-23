<script lang="ts">
  import { createClient } from '#lib/api/client.ts';
  import { approvalName, approvalStatus, haltLine, isAdmin } from '#lib/approvals.ts';
  import Button from '#lib/components/Button.svelte';
  import Empty from '#lib/components/Empty.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import MoreButton from '#lib/components/MoreButton.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import StatusBadge from '#lib/components/StatusBadge.svelte';
  import { clockTime, memberStage } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import { More } from '#lib/more.svelte.ts';
  import { IN_REVIEW } from '#lib/review.ts';
  import { MemberStage, Stage, type MemberSummary } from '#generated/ai-digestif-digestif-node.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const client = createClient();
  const members = $derived(
    new More(
      data.members,
      (m) => m.identity,
      (page) => client.members(page)
    )
  );

  // DES-85466: an admin sees Invite, or the halt line while a revoked key halts admissions, and each
  // waiting approval as a row of the same table, which opens its Inbox item.
  const self = $derived(members.rows.find((m) => m.is_self));
  const admin = $derived(isAdmin(self));
  const approvals = $derived('data' in data.approvals ? data.approvals.data : []);
  const halt = $derived('data' in data.signers ? haltLine(data.signers.data, approvals, self?.identity) : undefined);
  const loadErrors = $derived([
    ...('errors' in data.approvals ? data.approvals.errors : []),
    ...('errors' in data.signers ? data.signers.errors : [])
  ]);

  /** When their last note went out; a status note is not a note and is not counted. */
  function lastNote(m: MemberSummary): string {
    return m.last_note_at === undefined ? '' : clockTime(m.last_note_at);
  }
</script>

<PageHeader title="Members">
  {#snippet actions()}
    {#if admin && 'data' in data.signers && halt === undefined}
      <Button variant="primary" href={href.invite()}>Invite</Button>
    {/if}
  {/snippet}
</PageHeader>
{#if admin && halt}
  <p class="-mt-2 mb-4 flex flex-wrap gap-x-2 text-sm" role="status" data-testid="invites-halted">
    <span class="font-medium">{halt.text}</span>
    {#if halt.lift.href}<a class="dg-link" href={halt.lift.href}>{halt.lift.text}</a>{:else}<span class="dg-muted">{halt.lift.text}</span
      >{/if}
  </p>
{/if}
<ErrorBanner errors={admin ? loadErrors : []} />
<div class="dg-card overflow-hidden">
  <table class="w-full text-left text-sm" aria-label="Members">
    <thead class="dg-muted text-xs">
      <tr>
        <th scope="col" class="px-3 py-2 font-medium">Member</th>
        <th scope="col" class="px-3 py-2 font-medium">Agent</th>
        <th scope="col" class="px-3 py-2 font-medium">Stage</th>
        <th scope="col" class="hidden px-3 py-2 font-medium sm:table-cell">Last note</th>
      </tr>
    </thead>
    <tbody>
      {#each approvals as approval (approval.id)}
        {@const link = approval.item === undefined ? undefined : href.item(approval.item)}
        <tr class="border-t border-stone-200 hover:bg-stone-50 dark:border-stone-800 dark:hover:bg-stone-900" data-testid="approval-row">
          <td class="px-3 py-2"><a class="block min-h-11 py-1 font-medium" href={link}>{approvalName(approval)}</a></td>
          <td class="px-3 py-2"><a href={link} tabindex="-1" aria-hidden="true"></a></td>
          <td class="px-3 py-2"><a href={link} tabindex="-1"><StatusBadge wrap status={approvalStatus(approval, self?.identity)} /></a></td>
          <td class="hidden px-3 py-2 sm:table-cell"><a href={link} tabindex="-1" aria-hidden="true"></a></td>
        </tr>
      {/each}
      {#each members.rows as member (member.identity)}
        {@const link = href.member(member.identity)}
        <tr class="border-t border-stone-200 hover:bg-stone-50 dark:border-stone-800 dark:hover:bg-stone-900" data-testid="member-row">
          <td class="px-3 py-2">
            <a class="block min-h-11 py-1 font-medium" href={link}
              >{member.name}{member.is_self ? ' (you)' : ''}{isAdmin(member) ? ' · admin' : ''}{member.muted ? ' · muted' : ''}</a
            >
          </td>
          <td class="px-3 py-2" data-testid="member-agent">
            <a href={link} tabindex="-1">{member.stage === Stage.Onboarding ? '' : member.agent_name}</a>
          </td>
          <td class="px-3 py-2">
            <a href={link} tabindex="-1" class="inline-flex flex-wrap gap-1" data-testid="member-stage"
              ><StatusBadge status={memberStage(member.stage)} />{#if member.in_review_since}<StatusBadge status={IN_REVIEW} />{/if}</a
            >
          </td>
          <td class="dg-muted hidden px-3 py-2 text-xs sm:table-cell" data-testid="member-last-note">
            <a href={link} tabindex="-1">{lastNote(member)}</a>
          </td>
        </tr>
      {/each}
      {#each data.invitees as invitee (invitee.name + invitee.expires_at)}
        <tr class="border-t border-stone-200 dark:border-stone-800" data-testid="invitee-row">
          <td class="px-3 py-2"><span class="block min-h-11 py-1 font-medium">{invitee.name}</span></td>
          <td class="px-3 py-2"></td>
          <td class="px-3 py-2"><StatusBadge status={memberStage(MemberStage.Invited)} /></td>
          <td class="dg-muted hidden px-3 py-2 text-xs sm:table-cell">Invite expires {clockTime(invitee.expires_at)}</td>
        </tr>
      {/each}
      {#if members.rows.length === 0 && data.invitees.length === 0 && approvals.length === 0}
        <tr><td colspan="4"><Empty text="No members" /></td></tr>
      {/if}
    </tbody>
  </table>
</div>
<ErrorBanner errors={members.errors} />
<MoreButton list={members} label="More members" />
