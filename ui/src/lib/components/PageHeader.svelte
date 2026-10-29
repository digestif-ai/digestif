<script lang="ts">
  import type { Snippet } from 'svelte';

  interface Crumb {
    label: string;
    href: string;
  }

  interface Props {
    title: string;
    crumbs?: Crumb[];
    actions?: Snippet;
  }

  let { title, crumbs = [], actions }: Props = $props();
</script>

<header class="mb-4">
  {#if crumbs.length > 0}
    <nav aria-label="Breadcrumb" class="mb-1 text-sm">
      {#each crumbs as crumb (crumb.href)}
        <a class="dg-link" href={crumb.href}>{crumb.label}</a><span class="dg-muted mx-1">/</span>
      {/each}
    </nav>
  {/if}
  <div class="flex flex-wrap items-center justify-between gap-3">
    <h1 class="text-xl font-semibold break-words">{title}</h1>
    {#if actions}
      <div class="flex flex-wrap gap-2">{@render actions()}</div>
    {/if}
  </div>
</header>
