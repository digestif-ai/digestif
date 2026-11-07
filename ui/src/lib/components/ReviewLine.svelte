<script lang="ts">
  import { relativeTime } from '../format.ts';
  import ReviewText from './ReviewText.svelte';

  interface Props {
    reviewedAt: string | undefined;
    review: string | undefined;
    class?: string;
  }

  let { reviewedAt, review, class: extra = '' }: Props = $props();
</script>

<!-- What the member's Inbox agent did with another member's note: Reviewed, when, and its one line. -->
{#if reviewedAt !== undefined}
  <p class="dg-muted text-xs {extra}" data-testid="review-line">
    Reviewed {relativeTime(reviewedAt)}{#if review}: <ReviewText {review} />{/if}
  </p>
{/if}
