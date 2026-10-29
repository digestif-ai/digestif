<script lang="ts">
  import Empty from '#lib/components/Empty.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import StatusBadge from '#lib/components/StatusBadge.svelte';
  import { messageStatus, relativeTime } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const q = $derived(data.queue);
</script>

<PageHeader title="Approvals" />
<p class="mb-4 text-sm" data-testid="approval-progress">
  {Math.min(q.approved, q.required)} of {q.required} approved{q.approved >= q.required ? '; notes now go out unreviewed' : ''}
</p>
<ul class="dg-card dg-rows overflow-hidden" aria-label="Notes">
  {#each q.notes as note (note.hash)}
    <li>
      <a class="dg-row" href={href.approval(note.hash)} data-testid="approval-row">
        <div class="min-w-0 flex-1">
          <p class="truncate text-sm">{note.preview}</p>
          <p class="dg-muted text-xs">{relativeTime(note.created_at)}</p>
        </div>
        <StatusBadge status={messageStatus(note.status)} />
      </a>
    </li>
  {:else}
    <Empty text="No notes yet" />
  {/each}
</ul>
