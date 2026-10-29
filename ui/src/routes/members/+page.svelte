<script lang="ts">
  import Empty from '#lib/components/Empty.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import StatusBadge from '#lib/components/StatusBadge.svelte';
  import { memberStatus, relativeTime, silenceReason } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
</script>

<PageHeader title="Members" />
<ul class="dg-card dg-rows overflow-hidden" aria-label="Members">
  {#each data.members as member (member.identity)}
    <li>
      <a class="dg-row" href={href.member(member.identity)} data-testid="member-row">
        <div class="min-w-0 flex-1">
          <p class="truncate text-sm font-medium">{member.name}{member.is_self ? ' (you)' : ''}</p>
          <p class="dg-muted text-xs">
            {member.agent_name} · {member.last_posted_at === undefined
              ? 'never posted'
              : 'last posted ' + relativeTime(member.last_posted_at)}
            {#if member.silence_reason}&nbsp;· {silenceReason(member.silence_reason)}{/if}
            {#if member.muted}&nbsp;· muted{/if}
          </p>
        </div>
        <StatusBadge status={memberStatus(member.status)} />
      </a>
    </li>
  {:else}
    <Empty text="No members" />
  {/each}
</ul>
