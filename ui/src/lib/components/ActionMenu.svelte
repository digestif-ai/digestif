<script lang="ts" module>
  /** One act of the menu: it runs `onselect`, or opens `href`. */
  export type Action = { label: string; disabled?: boolean } & ({ onselect: () => void } | { href: string });
</script>

<script lang="ts">
  // A page header's one button: every act the page offers is an item of its menu, so a header holds at
  // most one button. Named by `label` ("Actions ▾"), or the ⋯ of a detail page's less frequent acts.
  // While an act's request is in flight the button names what it is doing (`busy`).

  interface Props {
    actions: Action[];
    /** The button's name; without one it is the ⋯ "More actions". */
    label?: string;
    /** The verb in progress ("Pausing…") while one of the menu's requests is in flight. */
    busy?: string | false;
    disabled?: boolean;
  }

  let { actions, label, busy = false, disabled = false }: Props = $props();
  let open = $state(false);
  let root: HTMLDivElement | undefined = $state();

  const itemClass =
    'block min-h-11 w-full px-4 py-2 text-left text-sm hover:bg-stone-50 disabled:cursor-not-allowed disabled:opacity-60 dark:hover:bg-stone-800';

  function choose(action: Action): void {
    open = false;
    if ('onselect' in action) action.onselect();
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
      class="inline-flex min-h-11 min-w-11 items-center justify-center gap-1 rounded-md border border-stone-300 bg-white text-sm hover:bg-stone-50 disabled:cursor-not-allowed disabled:opacity-60 dark:border-stone-700 dark:bg-stone-900 dark:hover:bg-stone-800 {label ===
      undefined
        ? ''
        : 'px-4 font-medium'}"
      aria-label={label === undefined && busy === false ? 'More actions' : undefined}
      aria-haspopup="menu"
      aria-expanded={open}
      aria-busy={busy !== false}
      disabled={disabled || busy !== false}
      onclick={() => (open = !open)}
    >
      {#if busy !== false}{busy}{:else if label === undefined}⋯{:else}{label}<span aria-hidden="true">▾</span>{/if}
    </button>
    {#if open}
      <div class="dg-card dg-rows absolute right-0 z-10 mt-1 min-w-52 overflow-hidden shadow-lg" role="menu">
        {#each actions as action (action.label)}
          {#if 'href' in action && !action.disabled}
            <a role="menuitem" class={itemClass} href={action.href} onclick={() => choose(action)}>{action.label}</a>
          {:else}
            <button type="button" role="menuitem" class={itemClass} disabled={action.disabled} onclick={() => choose(action)}
              >{action.label}</button
            >
          {/if}
        {/each}
      </div>
    {/if}
  </div>
{/if}
