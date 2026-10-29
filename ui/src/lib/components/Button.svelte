<script lang="ts">
  import type { Snippet } from 'svelte';

  interface Props {
    variant?: 'primary' | 'secondary' | 'danger';
    type?: 'button' | 'submit';
    /** The verb in progress ("Posting…") while this button's request is in flight. */
    busy?: string | false;
    disabled?: boolean;
    href?: string;
    onclick?: () => void;
    children: Snippet;
  }

  let { variant = 'secondary', type = 'button', busy = false, disabled = false, href, onclick, children }: Props = $props();

  const VARIANTS = {
    primary: 'bg-dg-accent text-white hover:bg-dg-accent-hover border-transparent',
    secondary:
      'bg-white text-stone-800 border-stone-300 hover:bg-stone-50 dark:bg-stone-900 dark:text-stone-100 dark:border-stone-700 dark:hover:bg-stone-800',
    danger: 'bg-white text-red-700 border-red-300 hover:bg-red-50 dark:bg-stone-900 dark:text-red-300 dark:border-red-900'
  } as const;
  const base =
    'inline-flex min-h-11 items-center justify-center rounded-md border px-4 text-sm font-medium disabled:cursor-not-allowed disabled:opacity-60';
</script>

{#if href !== undefined}
  <a class="{base} {VARIANTS[variant]}" {href}>{@render children()}</a>
{:else}
  <button class="{base} {VARIANTS[variant]}" {type} disabled={disabled || busy !== false} aria-busy={busy !== false} {onclick}>
    {#if busy !== false}{busy}{:else}{@render children()}{/if}
  </button>
{/if}
