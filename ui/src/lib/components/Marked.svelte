<script lang="ts">
  import { page } from '$app/state';
  import { markParts, searchWords } from '../highlight.ts';

  // A text with the words of a search marked where they matched (DIG-128). The words are the ones
  // given, else those of the search that opened the page (its `q`), so an item or a note opened from
  // a search result marks them too.
  interface Props {
    text: string;
    words?: string[] | undefined;
  }

  let { text, words }: Props = $props();
  const shown = $derived(words ?? searchWords(page.url.searchParams.get('q')));
</script>

{#each markParts(text, shown) as part, i (i)}{#if part.mark}<mark class="dg-mark" data-testid="search-mark">{part.text}</mark
    >{:else}{part.text}{/if}{/each}
