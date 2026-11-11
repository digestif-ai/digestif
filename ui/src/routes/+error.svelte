<script lang="ts">
  import { page } from '$app/state';
  import { href } from '#lib/href.ts';
  import { openCommand } from '#lib/open-command.ts';

  const phone = $derived(page.url.pathname === href.phone() || page.url.pathname.startsWith(href.phone() + '/'));
  // ISS-78222: a link from the digest reaches a browser with no session; it says what opens this page.
  const noSession = $derived(page.status === 401 && !phone);
</script>

<div class="mx-auto max-w-3xl px-3 pt-6 sm:px-6">
  <div class="dg-card p-6">
    <h1 class="text-xl font-semibold">
      {page.status === 404
        ? 'Not found'
        : noSession
          ? 'Open Digestif on this machine'
          : phone
            ? 'The relay did not answer'
            : 'The node did not answer'}
    </h1>
    {#if noSession}
      <p class="dg-muted mt-2 text-sm">Run this in a terminal on this machine, and this page opens:</p>
      <pre class="mt-2 overflow-x-auto text-sm"><code>{openCommand(page.url)}</code></pre>
    {:else}
      <p class="dg-muted mt-2 text-sm">{page.error?.message}</p>
      <a class="dg-link mt-4 inline-block text-sm" href={phone ? href.phone() : href.inbox()}
        >{phone ? 'Back to your choices' : 'Back to the inbox'}</a
      >
    {/if}
  </div>
</div>
