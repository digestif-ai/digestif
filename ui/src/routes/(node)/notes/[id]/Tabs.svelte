<script lang="ts">
  import { href } from '#lib/href.ts';

  interface Props {
    id: string;
    current: 'note' | 'log';
  }

  let { id, current }: Props = $props();
  const tab = 'inline-flex min-h-11 items-center border-b-2 px-3 text-sm';
  const on = 'border-dg-accent font-medium';
  const off = 'dg-muted border-transparent';
</script>

<nav class="mb-4 flex gap-2 border-b border-stone-200 dark:border-stone-800" aria-label="Views">
  <a class="{tab} {current === 'note' ? on : off}" href={href.note(id)} aria-current={current === 'note' ? 'page' : undefined}>Note</a>
  <a class="{tab} {current === 'log' ? on : off}" href={href.noteLog(id)} aria-current={current === 'log' ? 'page' : undefined}>Log</a>
</nav>
