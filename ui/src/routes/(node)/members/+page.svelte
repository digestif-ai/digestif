<script lang="ts">
  import Empty from '#lib/components/Empty.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import StatusBadge from '#lib/components/StatusBadge.svelte';
  import { clockTime, memberStage, statusNoteWords } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import { MemberStage, Stage, type MemberSummary } from '#generated/com-bryzek-digestif-node.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();

  /** When their last note went out, with a status note's fixed words beside it. */
  function lastNote(m: MemberSummary): string {
    if (m.last_note_at === undefined) return '';
    const at = clockTime(m.last_note_at);
    return m.last_status_note === undefined ? at : at + ' · ' + statusNoteWords(m.last_status_note, m.name);
  }
</script>

<PageHeader title="Members" />
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
      {#each data.members as member (member.identity)}
        {@const link = href.member(member.identity)}
        <tr class="border-t border-stone-200 hover:bg-stone-50 dark:border-stone-800 dark:hover:bg-stone-900" data-testid="member-row">
          <td class="px-3 py-2">
            <a class="block min-h-11 py-1 font-medium" href={link}
              >{member.name}{member.is_self ? ' (you)' : ''}{member.muted ? ' · muted' : ''}</a
            >
          </td>
          <td class="px-3 py-2" data-testid="member-agent">
            <a href={link} tabindex="-1">{member.stage === Stage.Onboarding ? '' : member.agent_name}</a>
          </td>
          <td class="px-3 py-2"><a href={link} tabindex="-1"><StatusBadge status={memberStage(member.stage)} /></a></td>
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
      {#if data.members.length === 0 && data.invitees.length === 0}
        <tr><td colspan="4"><Empty text="No members" /></td></tr>
      {/if}
    </tbody>
  </table>
</div>
