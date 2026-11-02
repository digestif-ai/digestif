<script lang="ts">
  import type { Snippet } from 'svelte';
  import { page } from '$app/state';
  import { Stage } from '#generated/com-bryzek-digestif-node.ts';
  import { href } from '#lib/href.ts';
  import { pauseWarningWords } from '#lib/pause.ts';
  import type { LayoutData } from './$types';

  interface Props {
    data: LayoutData;
    children: Snippet;
  }

  let { data, children }: Props = $props();

  const warning = $derived(data.status.pause_warning === undefined ? undefined : pauseWarningWords(data.status.pause_warning));
  const paused = $derived(data.status.stage === Stage.Paused);

  let dark = $state(typeof document !== 'undefined' && document.documentElement.dataset['theme'] === 'dark');

  const nav = $derived([
    { label: 'Feed', href: href.feed(), count: 0 },
    { label: 'Asks', href: href.asks(), count: data.status.open_asks },
    { label: 'Notes', href: href.notes(), count: data.status.notes_awaiting_approval },
    { label: 'Members', href: href.members(), count: 0 },
    { label: 'My brief', href: href.brief(), count: 0 },
    { label: 'Sources', href: href.sources(), count: 0 },
    { label: 'Rules', href: href.rules(), count: 0 }
  ]);

  function handleTheme(): void {
    dark = !dark;
    document.documentElement.dataset['theme'] = dark ? 'dark' : 'light';
    try {
      localStorage.setItem('digestif-theme', dark ? 'dark' : 'light');
    } catch {
      // a private window keeps the choice for this page only
    }
  }
</script>

<div class="mx-auto max-w-3xl px-3 pb-16 sm:px-6">
  <header class="flex items-center gap-3 py-4">
    <a href={href.feed()} class="text-lg font-semibold tracking-tight">Digestif</a>
    {#if data.status.member_name}
      <span class="dg-muted truncate text-sm">{data.status.member_name} · {data.status.agent_name}</span>
    {/if}
    <button
      type="button"
      class="dg-muted ml-auto min-h-11 rounded-md px-3 text-sm hover:text-stone-900 dark:hover:text-stone-100"
      onclick={handleTheme}
      aria-label="Toggle dark mode">{dark ? 'Light' : 'Dark'}</button
    >
  </header>
  {#if warning !== undefined && data.status.pause_warning !== undefined}
    <p
      class="mb-3 rounded-md bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-100"
      data-testid="pause-warning"
    >
      <a class="font-medium underline" href={href.note(data.status.pause_warning.note.id)}>{warning.note}</a>{warning.rest}
    </p>
  {/if}
  {#if !data.status.first_run && !paused}
    <nav aria-label="Sections" class="-mx-3 mb-6 overflow-x-auto border-b border-stone-200 px-3 dark:border-stone-800">
      <ul class="flex gap-1 whitespace-nowrap">
        {#each nav as item (item.href)}
          {@const active = page.url.pathname === item.href || page.url.pathname.startsWith(item.href + '/')}
          <li>
            <a
              href={item.href}
              aria-current={active ? 'page' : undefined}
              class="inline-flex min-h-11 items-center gap-1.5 border-b-2 px-3 text-sm {active
                ? 'border-dg-accent font-medium'
                : 'dg-muted border-transparent hover:text-stone-900 dark:hover:text-stone-100'}"
            >
              {item.label}
              {#if item.count > 0}<span class="rounded-full bg-stone-200 px-1.5 text-xs dark:bg-stone-700">{item.count}</span>{/if}
            </a>
          </li>
        {/each}
      </ul>
    </nav>
  {/if}
  <main>{@render children()}</main>
</div>
