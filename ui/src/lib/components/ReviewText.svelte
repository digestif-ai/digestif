<script lang="ts">
  import { reviewParts } from '../items.ts';
  import Marked from './Marked.svelte';

  interface Props {
    review: string;
    /** False on the phone app, which cannot open a note of the node's feed (DIG-448). */
    node?: boolean;
  }

  let { review, node = true }: Props = $props();
</script>

<!-- A line of text, every URL and owner/repo#n in it a link that opens it (DES-51007, The Inbox agent; DIG-448), and the words of the search that opened the page marked (DIG-128). -->
{#each reviewParts(review, { node }) as part, i (i)}{#if 'href' in part}<a class="dg-link" href={part.href} rel="noopener noreferrer"
      >{part.text}</a
    >{:else}<Marked text={part.text} />{/if}{/each}
