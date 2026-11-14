<script lang="ts">
  import { tick, type Snippet } from 'svelte';
  import { afterNavigate, goto } from '$app/navigation';
  import { page } from '$app/state';
  import { Stage, type NodeStatus } from '#generated/ai-digestif-digestif-node.ts';
  import { href } from '#lib/href.ts';
  import { pauseWarningWords } from '#lib/pause.ts';
  import { searchHref } from '#lib/search.ts';
  import type { LayoutData } from './$types';

  interface Props {
    data: LayoutData;
    children: Snippet;
  }

  let { data, children }: Props = $props();

  // The last status the node answered: the page renders before it arrives, and a reload of it
  // (invalidate digestif:status) keeps the counts on screen until the new one lands.
  let status = $state<NodeStatus | undefined>(undefined);
  $effect(() => {
    let current = true;
    data.status.then(
      (s) => {
        if (current) status = s;
      },
      () => {
        // A page that needs the status awaits it and shows the error; the header goes without counts.
      }
    );
    return () => {
      current = false;
    };
  });

  // While Paused the whole app is the Paused page, and the Paused page is nothing otherwise.
  $effect(() => {
    if (status === undefined) return;
    const onPaused = page.url.pathname === href.paused();
    if (status.stage === Stage.Paused && !onPaused) void goto(href.paused(), { replaceState: true });
    else if (status.stage !== Stage.Paused && onPaused) void goto(href.inbox(), { replaceState: true });
  });

  const warning = $derived(status?.pause_warning === undefined ? undefined : pauseWarningWords(status.pause_warning));
  const paused = $derived(status?.stage === Stage.Paused);

  let dark = $state(typeof document !== 'undefined' && document.documentElement.dataset['theme'] === 'dark');

  // A note is approved on its message, so the count of notes waiting for the member is Feed's.
  const nav = $derived([
    { label: 'Inbox', href: href.inbox(), count: status?.inbox ?? 0 },
    { label: 'Feed', href: href.feed(), count: status?.notes_awaiting_approval ?? 0 },
    { label: 'Members', href: href.members(), count: 0 },
    { label: 'Settings', href: href.settings(), count: 0 }
  ]);

  // The search box shows the query of the result page it is on, and is empty elsewhere.
  let query = $state('');
  $effect(() => {
    query = page.url.pathname === '/search' ? (page.url.searchParams.get('q') ?? '') : '';
  });

  // On a narrow screen the box is closed behind a magnifier and takes the header's row when open.
  let searchOpen = $state(false);
  let searchBox = $state<HTMLInputElement | undefined>(undefined);

  // The box stays open only on the result page; a phone keyboard has no Escape to close it.
  afterNavigate(({ to }) => {
    if (to?.url.pathname !== '/search') searchOpen = false;
  });

  async function openSearch(): Promise<void> {
    searchOpen = true;
    await tick();
    searchBox?.focus();
  }

  function handleSearch(event: SubmitEvent): void {
    event.preventDefault();
    void goto(searchHref(query));
  }

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
    <a href={href.inbox()} class="text-lg font-semibold tracking-tight {searchOpen ? 'hidden sm:inline' : ''}">Digestif</a>
    {#if status?.member_name}
      <span class="dg-muted truncate text-sm {searchOpen ? 'hidden sm:inline' : ''}">{status.member_name} · {status.agent_name}</span>
    {/if}
    {#if !(status?.first_run ?? false) && !paused}
      <form
        role="search"
        class="ml-auto flex min-w-0 items-center {searchOpen ? 'flex-1 sm:flex-none' : ''}"
        action="/search"
        onsubmit={handleSearch}
        data-testid="search-form"
      >
        <label class="sr-only" for="search-box">Search</label>
        {#if !searchOpen}
          <button
            type="button"
            class="dg-muted inline-flex min-h-11 min-w-11 items-center justify-center rounded-md hover:text-stone-900 sm:hidden dark:hover:text-stone-100"
            onclick={openSearch}
            aria-label="Open search"
            data-testid="search-toggle"
          >
            <svg
              aria-hidden="true"
              viewBox="0 0 24 24"
              class="h-5 w-5"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
            >
              <circle cx="11" cy="11" r="7" />
              <path d="M21 21l-4.3-4.3" />
            </svg>
          </button>
        {/if}
        <input
          id="search-box"
          name="q"
          type="search"
          enterkeyhint="search"
          autocomplete="off"
          placeholder="Search"
          bind:value={query}
          bind:this={searchBox}
          onkeydown={(e) => {
            if (e.key === 'Escape') searchOpen = false;
          }}
          onblur={() => {
            if (query.trim() === '') searchOpen = false;
          }}
          class="min-h-11 w-full rounded-full border border-stone-200 bg-stone-100 px-4 py-2 text-base sm:block sm:w-56 sm:text-sm dark:border-stone-800 dark:bg-stone-900 {searchOpen
            ? ''
            : 'hidden'}"
          data-testid="search-box"
        />
      </form>
    {/if}
    <button
      type="button"
      class="dg-muted {status?.first_run || paused
        ? 'ml-auto'
        : ''} inline-flex min-h-11 min-w-11 items-center justify-center rounded-md hover:text-stone-900 dark:hover:text-stone-100"
      onclick={handleTheme}
      aria-label={dark ? 'Switch to light mode' : 'Switch to dark mode'}
      data-testid="theme-toggle"
    >
      {#if dark}
        <!-- A sun: the mode this switches to. -->
        <svg
          aria-hidden="true"
          viewBox="0 0 24 24"
          class="h-5 w-5"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
        >
          <circle cx="12" cy="12" r="4" />
          <path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M4.93 19.07l1.41-1.41M17.66 6.34l1.41-1.41" />
        </svg>
      {:else}
        <!-- A moon: the mode this switches to. -->
        <svg
          aria-hidden="true"
          viewBox="0 0 24 24"
          class="h-5 w-5"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
        >
          <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />
        </svg>
      {/if}
    </button>
  </header>
  {#if warning !== undefined && status?.pause_warning !== undefined}
    <p
      class="mb-3 rounded-md bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-100"
      data-testid="pause-warning"
    >
      <a class="font-medium underline" href={href.note(status.pause_warning.note.id)}>{warning.note}</a>{warning.rest}
    </p>
  {/if}
  {#if !(status?.first_run ?? false) && !paused}
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
