<script lang="ts">
  import { page } from '$app/state';
  import { href } from '#lib/href.ts';
</script>

<div class="dg-card p-6">
  <h1 class="text-xl font-semibold">{page.status === 404 ? 'Not found' : 'The node did not answer'}</h1>
  <p class="dg-muted mt-2 text-sm">{page.error?.message}</p>
  <a class="dg-link mt-4 inline-block text-sm" href={href.feed()}>Back to the feed</a>
</div>
