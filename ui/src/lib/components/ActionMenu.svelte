<script lang="ts" module>
  import type { IconDef } from '#lib/icons.ts';
  import type { Sectioned } from '#lib/menu.ts';

  /** One act of the menu, drawn with its icon: it runs `onselect`, or opens `href`. */
  export type Action = { label: string; icon: IconDef; disabled?: boolean } & Sectioned & ({ onselect: () => void } | { href: string });
</script>

<script lang="ts">
  // A page header's one button: every act the page offers is an item of its menu, so a header holds at
  // most one button. Named by `label` ("Actions" with its chevron), or the ⋯ of a detail page's less
  // frequent acts. While an act's request is in flight the button names what it is doing (`busy`).
  //
  // The menu groups its acts into labeled sections (`section`), with what destroys something
  // (`danger`) red and last. It is portaled to body, placed under the button and flipped to fit,
  // closed by Escape, Tab and a click outside, and driven by the keyboard model of a WAI-ARIA menu
  // button (`#lib/menu.ts`); focus goes back to the button on close.
  import { tick } from 'svelte';
  import Icon from './Icon.svelte';
  import { chevronDown } from '#lib/icons.ts';
  import { menuKeyAction, menuSections, placeMenu, triggerKeyAction, type Placement } from '#lib/menu.ts';

  interface Props {
    actions: Action[];
    /** The button's name; without one it is the ⋯ "More actions". */
    label?: string;
    /** The verb in progress ("Pausing…") while one of the menu's requests is in flight. */
    busy?: string | false;
    disabled?: boolean;
  }

  let { actions, label, busy = false, disabled = false }: Props = $props();

  const id = Math.random().toString(36).slice(2, 10);
  const triggerId = `dg-actions-${id}`;
  const menuId = `dg-actions-menu-${id}`;

  let open = $state(false);
  // Null once unmounted: bind:this clears to null.
  let wrapper: HTMLDivElement | null = $state(null);
  let trigger: HTMLButtonElement | null = $state(null);
  let menu: HTMLDivElement | null = $state(null);
  // Measured after it mounts, so the menu stays invisible for that first frame.
  let placement = $state<Placement | undefined>(undefined);
  let initialFocus: 'first' | 'last' | 'menu' = 'menu';

  const sections = $derived(menuSections(actions));
  const held = $derived(disabled || busy !== false);
  // An act that empties the menu (Edit puts the page in edit mode) takes the button away: the menu goes with it.
  const shown = $derived(open && actions.length > 0);

  function items(): HTMLElement[] {
    return menu === null ? [] : [...menu.querySelectorAll<HTMLElement>('[role="menuitem"]')];
  }

  function openMenu(focus: 'first' | 'last' | 'menu'): void {
    initialFocus = focus;
    placement = undefined;
    open = true;
  }

  // Deferred one macrotask so an item's own default action (a link's navigation) runs before the menu
  // leaves the DOM.
  function closeMenu(refocus: boolean): void {
    setTimeout(() => {
      if (!open) return;
      const active = document.activeElement;
      const unclaimed = active === null || active === document.body || active === trigger || (menu?.contains(active) ?? false);
      open = false;
      if (refocus && unclaimed) trigger?.focus();
    }, 0);
  }

  function choose(event: MouseEvent, action: Action): void {
    if (action.disabled === true) {
      event.preventDefault();
      return;
    }
    if ('onselect' in action) action.onselect();
    closeMenu(true);
  }

  function onTriggerKeydown(event: KeyboardEvent): void {
    const action = triggerKeyAction(event.key);
    if (action.kind === 'none') return;
    event.preventDefault();
    openMenu(action.focus);
  }

  function onMenuKeydown(event: KeyboardEvent): void {
    const list = items();
    const current = list.findIndex((item) => item === document.activeElement);
    const action = menuKeyAction(
      event.key,
      current,
      list.map((item) => item.textContent ?? '')
    );
    if (action.kind === 'none') return;
    if (action.kind === 'close') {
      if (action.refocus) event.preventDefault();
      closeMenu(action.refocus);
      return;
    }
    event.preventDefault();
    list[action.index]?.focus();
  }

  function onWindowClick(event: MouseEvent): void {
    const target = event.target as Node | null;
    if (!open || target === null) return;
    // The menu is portaled out of the wrapper, so it is tested on its own.
    if (wrapper?.contains(target) || menu?.contains(target)) return;
    closeMenu(false);
  }

  function onWindowKeydown(event: KeyboardEvent): void {
    if (open && event.key === 'Escape' && !menu?.contains(event.target as Node | null)) closeMenu(true);
  }

  /** Moves the menu to body so no ancestor can clip it. */
  function portal(node: HTMLElement): { destroy: () => void } {
    document.body.appendChild(node);
    return { destroy: () => node.remove() };
  }

  function position(): void {
    if (wrapper === null || menu === null) return;
    const box = menu.getBoundingClientRect();
    placement = placeMenu(wrapper.getBoundingClientRect(), box, { width: window.innerWidth, height: window.innerHeight });
  }

  $effect(() => {
    if (!shown || menu === null) return;
    position();
    void tick().then(() => {
      const list = items();
      if (initialFocus === 'first') list[0]?.focus();
      else if (initialFocus === 'last') list[list.length - 1]?.focus();
      else menu?.focus();
    });
    // Capture-phase scroll, so the menu follows the button inside a scrolling container too.
    window.addEventListener('scroll', position, true);
    window.addEventListener('resize', position);
    return () => {
      window.removeEventListener('scroll', position, true);
      window.removeEventListener('resize', position);
    };
  });

  // A held menu does not stay open behind the button that holds it.
  $effect(() => {
    if ((held || actions.length === 0) && open) open = false;
  });

  const itemClass =
    'group flex min-h-10 w-full items-center gap-2.5 rounded-md px-2.5 text-left text-sm text-stone-900 no-underline hover:bg-dg-accent/8 focus-visible:bg-dg-accent/8 focus-visible:outline-none max-sm:min-h-11 dark:text-stone-100 dark:hover:bg-pink-300/10 dark:focus-visible:bg-pink-300/10 aria-disabled:cursor-not-allowed aria-disabled:opacity-55 aria-disabled:hover:bg-transparent';
  const iconClass =
    'text-stone-500 group-hover:text-dg-accent group-focus-visible:text-dg-accent dark:text-stone-400 dark:group-hover:text-pink-300 dark:group-focus-visible:text-pink-300';
  const dangerClass = '!text-red-700 dark:!text-red-300 hover:!bg-red-700/8 focus-visible:!bg-red-700/8 dark:hover:!bg-red-300/10';
</script>

<svelte:window onclick={onWindowClick} onkeydown={onWindowKeydown} />

{#if actions.length > 0}
  <div class="relative inline-flex" bind:this={wrapper}>
    <button
      bind:this={trigger}
      id={triggerId}
      type="button"
      class="inline-flex min-h-11 items-stretch overflow-hidden rounded-md border border-stone-300 bg-white p-0 text-sm font-semibold text-stone-900 shadow-xs hover:bg-stone-50 focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-dg-accent disabled:cursor-not-allowed disabled:opacity-55 dark:border-stone-700 dark:bg-stone-900 dark:text-stone-100 dark:hover:bg-stone-800"
      aria-label={label === undefined && busy === false ? 'More actions' : undefined}
      aria-haspopup="menu"
      aria-expanded={open}
      aria-controls={open ? menuId : undefined}
      aria-busy={busy !== false}
      disabled={held}
      onclick={() => (open ? closeMenu(false) : openMenu('menu'))}
      onkeydown={onTriggerKeydown}
    >
      {#if busy !== false}
        <span class="flex items-center px-3.5">{busy}</span>
      {:else if label === undefined}
        <span class="flex min-w-11 items-center justify-center">⋯</span>
      {:else}
        <span class="flex items-center px-3.5">{label}</span>
        <span
          class="flex items-center border-l border-stone-300 bg-stone-50 px-2.5 text-stone-500 dark:border-stone-700 dark:bg-stone-800/60 dark:text-stone-400"
          ><Icon icon={chevronDown} size={15} class={open ? 'rotate-180' : ''} /></span
        >
      {/if}
    </button>
  </div>
{/if}

{#if shown}
  <div
    bind:this={menu}
    use:portal
    id={menuId}
    role="menu"
    tabindex="-1"
    aria-labelledby={triggerId}
    class="fixed z-50 box-border w-68 max-w-[calc(100vw-16px)] rounded-[10px] border border-stone-200 bg-white p-1.5 text-sm shadow-[0_18px_40px_-12px_rgb(28_25_23/20%),0_4px_10px_-4px_rgb(28_25_23/8%)] focus:outline-none dark:border-stone-800 dark:bg-stone-900 dark:shadow-[0_18px_40px_-12px_rgb(0_0_0/60%)]"
    style:top="{placement?.top ?? 0}px"
    style:left="{placement?.left ?? 0}px"
    style:width={placement?.width === undefined ? undefined : `${placement.width}px`}
    style:visibility={placement === undefined ? 'hidden' : undefined}
    onkeydown={onMenuKeydown}
  >
    {#each sections as section, i (section.label ?? (section.danger ? '!danger' : '!plain'))}
      <div role="group" aria-label={section.label} class={i > 0 ? 'mt-1.5 border-t border-stone-200 pt-1.5 dark:border-stone-800' : ''}>
        {#if section.label !== undefined}
          <div class="px-2.5 pt-2 pb-1 text-[11px] font-bold tracking-widest text-stone-500 uppercase dark:text-stone-400">
            {section.label}
          </div>
        {/if}
        {#each section.items as action (action.label)}
          {@const red = section.danger}
          {#if 'href' in action && action.disabled !== true}
            <a
              role="menuitem"
              tabindex="-1"
              class="{itemClass} {red ? dangerClass : ''}"
              href={action.href}
              onclick={(e) => choose(e, action)}
            >
              <Icon icon={action.icon} class={red ? '' : iconClass} /><span class="flex-1">{action.label}</span>
            </a>
          {:else}
            <button
              type="button"
              role="menuitem"
              tabindex="-1"
              class="{itemClass} {red ? dangerClass : ''}"
              aria-disabled={action.disabled === true ? 'true' : undefined}
              onclick={(e) => choose(e, action)}
            >
              <Icon icon={action.icon} class={red ? '' : iconClass} /><span class="flex-1">{action.label}</span>
            </button>
          {/if}
        {/each}
      </div>
    {/each}
  </div>
{/if}
