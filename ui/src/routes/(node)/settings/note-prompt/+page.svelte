<script lang="ts">
  import { createClient } from '#lib/api/client.ts';
  import Button from '#lib/components/Button.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import MoreButton from '#lib/components/MoreButton.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import StatusBadge from '#lib/components/StatusBadge.svelte';
  import { relativeTime, suggestionStatus } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import { More } from '#lib/more.svelte.ts';
  import { releasePrompt } from '#lib/note-prompt.ts';
  import type { PageData } from './$types';

  // The circle's nightly note prompt and every suggestion to change it (ISS-51009). A suggestion is
  // judged by its author and the members they name; one every judge picks becomes the circle's.
  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const np = $derived(data.notePrompt);
  const client = createClient();
  const suggestions = $derived(
    new More(
      data.suggestions,
      (s) => s.hash,
      (page) => client.promptSuggestions(page)
    )
  );
</script>

<PageHeader title="Note prompt" crumbs={[{ label: 'Settings', href: href.settings() }]}>
  {#snippet actions()}
    <Button variant="primary" href={href.suggestPrompt()}>Suggest a change</Button>
  {/snippet}
</PageHeader>

<section class="mb-6" aria-label="The circle's prompt" data-testid="live-prompt">
  <h2 class="dg-label mb-2">The circle's prompt</h2>
  <div class="dg-card p-4">
    {#if np.adoption === undefined}
      <p class="dg-muted mb-3 text-xs">The release's prompt</p>
    {:else}
      <p class="dg-muted mb-3 text-xs">
        <a class="dg-link" href={href.promptSuggestion(np.adoption.suggestion)}>{np.adoption.author.name}'s suggestion</a>, adopted
        {relativeTime(np.adoption.at)}
      </p>
    {/if}
    <p class="font-mono text-xs whitespace-pre-wrap" data-testid="live-prompt-text">{np.text ?? releasePrompt}</p>
  </div>
</section>

<h2 class="dg-label mb-2">Suggestions</h2>
<ul class="dg-card dg-rows overflow-hidden" aria-label="Suggestions">
  {#each suggestions.rows as s (s.hash)}
    <li>
      <a class="dg-row" href={href.promptSuggestion(s.hash)} data-testid="suggestion-row">
        <span class="min-w-0 flex-1 truncate text-sm">{s.change || 'Withdrawn suggestion'}</span>
        <span class="dg-muted text-xs">{s.author.name}</span>
        <StatusBadge status={suggestionStatus(s.status)} />
        <span class="dg-muted text-xs">{relativeTime(s.created_at)}</span>
      </a>
    </li>
  {:else}
    <li class="dg-muted px-4 py-6 text-center text-sm">No suggestions</li>
  {/each}
</ul>
<ErrorBanner errors={suggestions.errors} />
<MoreButton list={suggestions} label="More suggestions" />
