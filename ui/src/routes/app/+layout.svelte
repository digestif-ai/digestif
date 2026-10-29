<script lang="ts">
  import type { Snippet } from 'svelte';
  import { href } from '#lib/href.ts';

  interface Props {
    children: Snippet;
  }

  let { children }: Props = $props();
</script>

<svelte:head>
  <link rel="manifest" href="/app/manifest.webmanifest" />
  <meta name="theme-color" content="#1c1917" />
</svelte:head>

<div class="mx-auto max-w-xl px-3 pb-16">
  <header class="flex items-center gap-3 py-4">
    <a href={href.phone()} class="text-lg font-semibold tracking-tight">Digestif</a>
  </header>
  <main>{@render children()}</main>
</div>
