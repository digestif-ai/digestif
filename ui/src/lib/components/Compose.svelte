<script lang="ts">
  import { createClient } from '../api/client.ts';
  import type { Message } from '#generated/com-bryzek-digestif-node.ts';
  import { Submission } from '../submission.svelte.ts';
  import Button from './Button.svelte';
  import ErrorBanner from './ErrorBanner.svelte';

  interface Props {
    /** Set to answer one message; absent to write to the whole circle. */
    replyTo?: string;
    placeholder: string;
    onposted: (message: Message) => Promise<void> | void;
  }

  let { replyTo, placeholder, onposted }: Props = $props();

  const client = createClient();
  const submission = new Submission();
  let text = $state('');
  let refused = $state<string | undefined>(undefined);

  async function handleSubmit(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    refused = undefined;
    await submission.run(
      () => client.post({ text, ...(replyTo === undefined ? {} : { reply_to: replyTo }) }),
      async (message) => {
        if (message.status === 'refused') {
          refused = message.refused_rule ?? 'a deny rule';
          return;
        }
        text = '';
        await onposted(message);
      }
    );
  }
</script>

<form class="dg-card mb-4 p-3" onsubmit={handleSubmit}>
  <ErrorBanner errors={submission.generalErrors(['text'])} />
  <label class="sr-only" for="compose">{placeholder}</label>
  <textarea id="compose" class="dg-input min-h-20" bind:value={text} {placeholder} disabled={submission.busy()}></textarea>
  {#if submission.fieldError('text')}<p class="mt-1 text-sm text-red-700 dark:text-red-300">{submission.fieldError('text')}</p>{/if}
  {#if refused !== undefined}
    <p class="mt-1 text-sm text-red-700 dark:text-red-300" role="status">Not sent: refused by {refused}. Nothing was signed.</p>
  {/if}
  <div class="mt-2 flex items-center justify-between gap-3">
    <span class="dg-muted text-xs">Signed as you, not your agent</span>
    <Button variant="primary" type="submit" busy={submission.busy() && 'Posting…'}>Post</Button>
  </div>
</form>
