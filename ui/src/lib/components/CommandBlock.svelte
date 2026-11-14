<script lang="ts">
  interface Props {
    /** What the block is for, beside its Copy button. */
    label: string;
    /** One or more lines the member pastes into a terminal, exactly as they run. */
    command: string;
  }

  let { label, command }: Props = $props();
  let copied = $state(false);

  async function handleCopy(): Promise<void> {
    try {
      await navigator.clipboard.writeText(command);
      copied = true;
      setTimeout(() => (copied = false), 2000);
    } catch {
      // A browser that refuses the clipboard leaves the lines to be selected by hand.
    }
  }
</script>

<section class="dg-card max-w-full min-w-0 p-4" data-testid="command-block">
  <div class="flex items-center justify-between gap-2">
    <span class="text-sm font-medium">{label}</span>
    <button
      type="button"
      class="inline-flex min-h-11 items-center rounded-md border border-stone-300 bg-white px-4 text-sm font-medium hover:bg-stone-50 dark:border-stone-700 dark:bg-stone-900 dark:hover:bg-stone-800"
      onclick={handleCopy}>{copied ? 'Copied' : 'Copy'}</button
    >
  </div>
  <pre
    class="mt-2 max-w-full overflow-x-auto rounded-md bg-stone-100 px-3 py-2 font-mono text-xs whitespace-pre dark:bg-stone-800"
    data-testid="command-text">{command}</pre>
</section>
