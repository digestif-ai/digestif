<script lang="ts">
  interface Props {
    /** A command the member runs in a terminal, exactly as it is to be pasted. */
    command: string;
  }

  let { command }: Props = $props();
  let copied = $state(false);

  async function handleCopy(): Promise<void> {
    try {
      await navigator.clipboard.writeText(command);
      copied = true;
      setTimeout(() => (copied = false), 2000);
    } catch {
      // A browser that refuses the clipboard leaves the command to be selected by hand.
    }
  }
</script>

<span class="inline-flex max-w-full items-center gap-1 rounded-md bg-stone-100 align-middle dark:bg-stone-800" data-testid="command">
  <code class="overflow-x-auto px-2 py-1 font-mono text-sm whitespace-nowrap">{command}</code>
  <button
    type="button"
    class="dg-muted inline-flex min-h-11 min-w-11 items-center justify-center rounded-md hover:text-stone-900 dark:hover:text-stone-100"
    aria-label={copied ? 'Copied' : 'Copy the command'}
    title={copied ? 'Copied' : 'Copy'}
    onclick={handleCopy}
  >
    {#if copied}
      <svg
        aria-hidden="true"
        viewBox="0 0 24 24"
        class="h-4 w-4"
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <path d="M20 6 9 17l-5-5" />
      </svg>
    {:else}
      <svg
        aria-hidden="true"
        viewBox="0 0 24 24"
        class="h-4 w-4"
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <rect x="9" y="9" width="13" height="13" rx="2" />
        <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
      </svg>
    {/if}
  </button>
</span>
