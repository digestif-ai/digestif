<script lang="ts">
  import { categoryLabel, shownVersions } from '#lib/changelog.ts';
  import Empty from '#lib/components/Empty.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import { relativeTime } from '#lib/format.ts';
  import type { PageData } from './$types';

  // What each release changed (DIG-128): the running version and every one before it, newest first,
  // each with the entries its release carries.
  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const versions = $derived(shownVersions(data.changelog, data.version));
</script>

<PageHeader title="What's new" />

{#each versions as v (v.version)}
  <section class="mb-6" aria-labelledby="version-{v.version}" data-testid="changelog-version">
    <h2 id="version-{v.version}" class="mb-1 flex items-baseline gap-2 text-sm font-medium">
      <span>{v.version}</span>
      {#if v.version === data.version}<span class="dg-muted text-xs font-normal" data-testid="changelog-running">this node</span>{/if}
      {#if v.released_at}<span class="dg-muted ml-auto text-xs font-normal">{relativeTime(v.released_at)}</span>{/if}
    </h2>
    {#if v.entries.length > 0}
      <ul class="dg-card dg-rows">
        {#each v.entries as e, i (i)}
          <li class="flex gap-3 px-4 py-3 text-sm" data-testid="changelog-entry">
            <span class="dg-muted w-16 shrink-0 text-xs leading-5">{categoryLabel(e.category)}</span>
            <span class="break-words">{e.summary}</span>
          </li>
        {/each}
      </ul>
    {:else}
      <p class="dg-muted text-sm">No notes for this version.</p>
    {/if}
  </section>
{:else}
  <Empty text="No release notes yet" />
{/each}
