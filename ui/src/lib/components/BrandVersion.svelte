<script lang="ts">
  // The node's version under the name in the header (DIG-523). A node that sends none, an older
  // one or a failed status call, shows nothing and the header keeps its layout.
  interface Props {
    version?: string | undefined;
  }

  let { version }: Props = $props();
</script>

{#if version !== undefined && version !== ''}
  <span class="dg-muted text-xs leading-none" data-testid="node-version">{version}</span>
{/if}
