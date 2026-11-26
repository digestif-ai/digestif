<script lang="ts">
  import { SourceKind, type Source } from '#generated/ai-digestif-digestif-node.ts';
  import { sourceKind } from '../format.ts';

  interface Props {
    source: Source;
  }

  let { source }: Props = $props();
</script>

<div class="min-w-0 flex-1">
  <p class="text-sm font-medium">{source.label} <span class="dg-muted font-normal">· {sourceKind(source.kind)}</span></p>
  <p class="dg-muted text-xs break-all">{source.kind === SourceKind.Command ? source.paths.join(' ') : source.paths.join(', ')}</p>
  {#if source.folders !== undefined}
    <p class="dg-muted text-xs break-all">Sessions started in: {source.folders.length === 0 ? 'no folder' : source.folders.join(', ')}</p>
  {/if}
  <p class="dg-muted text-xs">Yields: {source.yields.join(', ')}</p>
</div>
