<script lang="ts">
  import { href } from '../href.ts';

  // The node's version at the right of the footer (DIG-523, DIG-128), the link to what each release
  // changed. A node that sends none, an older one or a failed status call, shows nothing.
  interface Props {
    version?: string | undefined;
  }

  let { version }: Props = $props();
</script>

{#if version !== undefined && version !== ''}
  <a class="dg-muted text-xs hover:underline" href={href.changelog()} title="What's new" data-testid="node-version">{version}</a>
{/if}
