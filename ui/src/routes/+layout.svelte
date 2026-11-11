<script lang="ts">
  import '../app.css';
  import type { Snippet } from 'svelte';

  interface Props {
    children: Snippet;
  }

  let { children }: Props = $props();

  // The app has rendered (a page or the error page): the shell's loading state goes. ISS-78820
  $effect(() => {
    document.getElementById('dg-boot')?.remove();
  });
</script>

{@render children()}
