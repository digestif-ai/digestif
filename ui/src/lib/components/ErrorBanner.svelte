<script lang="ts">
  import type { NodeError } from '../api/types.ts';

  interface Props {
    errors: NodeError[];
  }

  let { errors }: Props = $props();
</script>

{#if errors.length > 0}
  <div
    role="alert"
    class="mb-4 rounded-md border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-200"
  >
    {#each errors as error, i (i)}
      <p>{error.message}</p>
    {/each}
  </div>
{/if}
