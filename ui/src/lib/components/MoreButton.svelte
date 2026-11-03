<script lang="ts" generics="T">
  import Button from './Button.svelte';
  import type { More } from '#lib/more.svelte.ts';

  interface Props {
    /** The list whose next page this reads (ISS-41988). */
    list: More<T>;
    label: string;
  }

  let { list, label }: Props = $props();
</script>

{#if list.more}
  <div class="mt-4">
    <Button busy={list.loading && 'Loading…'} onclick={() => void list.load()}>{label}</Button>
  </div>
{/if}
