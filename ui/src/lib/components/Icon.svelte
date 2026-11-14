<script lang="ts">
  // Draws one of `#lib/icons.ts` in the current text color.
  import type { IconDef } from '#lib/icons.ts';

  interface Props {
    icon: IconDef;
    /** Width and height in pixels. */
    size?: number;
    class?: string;
  }

  let { icon, size = 17, class: className = '' }: Props = $props();
</script>

<svg
  class="flex-none {className}"
  width={size}
  height={size}
  fill="none"
  viewBox="0 0 24 24"
  stroke="currentColor"
  aria-hidden="true"
  focusable="false"
>
  {#each icon.paths as path (path)}
    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d={path}></path>
  {/each}
</svg>
