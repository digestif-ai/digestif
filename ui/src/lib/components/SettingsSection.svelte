<script lang="ts">
  import type { Snippet } from 'svelte';
  import Button from './Button.svelte';

  interface Props {
    title: string;
    /** The section's edit page; a section with none (the always-on rule) has no Change. */
    change?: string;
    testid: string;
    children: Snippet;
  }

  let { title, change, testid, children }: Props = $props();
</script>

<section class="mb-6" aria-label={title} data-testid={testid}>
  <div class="mb-2 flex min-h-11 items-center justify-between gap-3">
    <h2 class="dg-label">{title}</h2>
    {#if change !== undefined}<Button href={change}>Change</Button>{/if}
  </div>
  <div class="dg-card p-4">{@render children()}</div>
</section>
