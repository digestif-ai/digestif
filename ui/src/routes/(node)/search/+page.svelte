<script lang="ts">
  import Empty from '#lib/components/Empty.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const asked = $derived(data.q.trim() !== '');
</script>

<PageHeader title={asked ? 'Search: ' + data.q.trim() : 'Search'} />

{#if !asked}
  <Empty text="Type in the box above to search the Inbox, the feed, notes, members and settings." />
{:else}
  {#await data.result}
    <p class="dg-muted py-8 text-center text-sm" data-testid="search-loading">Searching</p>
  {:then result}
    {#if result.failed !== undefined}
      <div class="mb-3" data-testid="search-failed">
        <ErrorBanner errors={[{ code: 'search', message: result.failed }]} />
      </div>
    {/if}
    {#each result.groups as group (group.kind)}
      <section class="mb-6" aria-labelledby="search-{group.kind}" data-testid="search-group-{group.kind}">
        <h2 id="search-{group.kind}" class="dg-muted mb-1 text-sm font-medium">{group.label}</h2>
        <ul class="dg-rows">
          {#each group.hits as hit (hit.href)}
            <li>
              <a class="block min-h-11 px-4 py-3 hover:bg-stone-50 dark:hover:bg-stone-900" href={hit.href} data-testid="search-hit">
                <span class="block text-sm break-words">{hit.title}</span>
                {#if hit.detail}<span class="dg-muted block text-xs break-words">{hit.detail}</span>{/if}
              </a>
            </li>
          {/each}
        </ul>
      </section>
    {:else}
      {#if result.failed === undefined}<Empty text="Nothing matches that." />{/if}
    {/each}
  {:catch}
    <ErrorBanner errors={[{ code: 'search', message: 'The search failed.' }]} />
  {/await}
{/if}
