<script lang="ts">
  import type { Source } from '../api/types.ts';
  import { sourceKind } from '../format.ts';

  interface Props {
    source: Source;
  }

  let { source }: Props = $props();
</script>

<div class="min-w-0 flex-1">
  <p class="text-sm font-medium">{source.label} <span class="dg-muted font-normal">· {sourceKind(source.kind)}</span></p>
  <p class="dg-muted text-xs break-all">{source.paths.join(', ')}</p>
  <p class="dg-muted text-xs">Yields: {source.yields.join(', ')}</p>
</div>
