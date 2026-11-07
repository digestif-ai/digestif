<script lang="ts">
  import { reviewParts } from '../items.ts';

  interface Props {
    review: string;
  }

  let { review }: Props = $props();
</script>

<!-- A review line, every URL and owner/repo#n in it a link that opens it (DES-51007, The Inbox agent). -->
{#each reviewParts(review) as part, i (i)}{#if 'href' in part}<a class="dg-link" href={part.href} rel="noopener noreferrer">{part.text}</a
    >{:else}{part.text}{/if}{/each}
