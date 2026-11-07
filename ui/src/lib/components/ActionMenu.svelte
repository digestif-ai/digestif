<script lang="ts">
  // The ⋯ menu in a detail page's header: the page's less frequent acts, each one a menu item.
  interface Action {
    label: string;
    onselect: () => void;
  }

  interface Props {
    actions: Action[];
    disabled?: boolean;
  }

  let { actions, disabled = false }: Props = $props();
  let open = $state(false);
  let root: HTMLDivElement | undefined = $state();

  function choose(action: Action): void {
    open = false;
    action.onselect();
  }

  function handleWindowClick(e: MouseEvent): void {
    if (open && root !== undefined && !root.contains(e.target as Node)) open = false;
  }
</script>

<svelte:window onclick={handleWindowClick} onkeydown={(e) => e.key === 'Escape' && (open = false)} />

{#if actions.length > 0}
  <div class="relative" bind:this={root}>
    <button
      type="button"
      class="inline-flex min-h-11 min-w-11 items-center justify-center rounded-md border border-stone-300 bg-white text-sm hover:bg-stone-50 dark:border-stone-700 dark:bg-stone-900 dark:hover:bg-stone-800"
      aria-label="More actions"
      aria-haspopup="menu"
      aria-expanded={open}
      {disabled}
      onclick={() => (open = !open)}>⋯</button
    >
    {#if open}
      <div class="dg-card dg-rows absolute right-0 z-10 mt-1 min-w-52 overflow-hidden shadow-lg" role="menu">
        {#each actions as action (action.label)}
          <button
            type="button"
            role="menuitem"
            class="block min-h-11 w-full px-4 py-2 text-left text-sm hover:bg-stone-50 dark:hover:bg-stone-800"
            onclick={() => choose(action)}>{action.label}</button
          >
        {/each}
      </div>
    {/if}
  </div>
{/if}
