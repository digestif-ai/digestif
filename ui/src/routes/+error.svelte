<script lang="ts">
  import { page } from '$app/state';
  import { href } from '#lib/href.ts';

  const phone = $derived(page.url.pathname === href.phone() || page.url.pathname.startsWith(href.phone() + '/'));
</script>

<div class="mx-auto max-w-3xl px-3 pt-6 sm:px-6">
  <div class="dg-card p-6">
    <h1 class="text-xl font-semibold">
      {page.status === 404 ? 'Not found' : phone ? 'The relay did not answer' : 'The node did not answer'}
    </h1>
    <p class="dg-muted mt-2 text-sm">{page.error?.message}</p>
    <a class="dg-link mt-4 inline-block text-sm" href={phone ? href.phone() : href.feed()}
      >{phone ? 'Back to your asks' : 'Back to the feed'}</a
    >
  </div>
</div>
