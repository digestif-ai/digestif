<script lang="ts">
  import type { StatusLabel } from '../format.ts';

  interface Props {
    status: StatusLabel;
    /** Wrap a long label onto a second line rather than clip it at phone width ("Waiting on Roman · 2 of 3"). */
    wrap?: boolean;
  }

  let { status, wrap = false }: Props = $props();

  const TONES = {
    neutral: 'bg-stone-100 text-stone-600 dark:bg-stone-800 dark:text-stone-300',
    good: 'bg-emerald-50 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300',
    warn: 'bg-amber-50 text-amber-800 dark:bg-amber-950 dark:text-amber-300',
    bad: 'bg-red-50 text-red-700 dark:bg-red-950 dark:text-red-300',
    info: 'bg-sky-50 text-sky-700 dark:bg-sky-950 dark:text-sky-300'
  } as const;
</script>

<span
  class="inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium {wrap
    ? 'leading-snug sm:whitespace-nowrap'
    : 'shrink-0'} {TONES[status.tone]}"
  data-tone={status.tone}>{status.label}</span
>
