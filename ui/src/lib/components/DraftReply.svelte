<script lang="ts">
  import { invalidateAll } from '$app/navigation';
  import { ReplyDraftStatus, type ItemAgentAnswer, type Message, type ReplyDraft } from '#generated/com-bryzek-digestif-node.ts';
  import { createClient } from '../api/client.ts';
  import { Submission } from '../submission.svelte.ts';
  import Button from './Button.svelte';
  import Compose from './Compose.svelte';
  import ErrorBanner from './ErrorBanner.svelte';

  // A reply to another member's note, from the draft the member's Inbox agent wrote (ISS-83154): the
  // draft fills the form, which the member edits and sends as their own. With no draft, Draft a reply
  // asks the agent for one now, and the page looks again until it is there.
  interface Props {
    /** The note replied to. */
    replyTo: string;
    agentName: string;
    agentAnswer?: ItemAgentAnswer | undefined;
    draftReply?: ReplyDraft | undefined;
    /** Whether the member may post now: a reply is a note in the circle. */
    canPost: boolean;
    /** Show the empty form beside Draft a reply, for a page where the member also writes their own. */
    alwaysCompose?: boolean;
    onposted: (message: Message) => Promise<void> | void;
  }

  let { replyTo, agentName, agentAnswer, draftReply, canPost, alwaysCompose = false, onposted }: Props = $props();

  const client = createClient();
  const submission = new Submission();
  const drafting = $derived(draftReply?.status === ReplyDraftStatus.Asked);

  /** While the agent is drafting, the page looks again every few seconds. */
  $effect(() => {
    if (!drafting) return;
    const timer = setInterval(() => void invalidateAll(), 3000);
    return () => clearInterval(timer);
  });

  const ask = (): Promise<void> =>
    submission.run(
      () => client.draftReply(replyTo),
      () => invalidateAll()
    );
</script>

{#if agentAnswer}
  <h2 class="dg-label mt-6 mb-2">{agentName}'s draft reply</h2>
  {#if agentAnswer.reason}<p class="dg-muted mb-2 text-sm" data-testid="draft-reply-reason">{agentAnswer.reason}</p>{/if}
  {#if canPost}
    {#key agentAnswer.created_at}
      <Compose
        {replyTo}
        placeholder="Your reply"
        initial={agentAnswer.text}
        action={{ label: 'Send reply', busy: 'Sending…' }}
        {onposted}
      />
    {/key}
  {:else}
    <div class="dg-card p-4" data-testid="draft-reply-text"><p class="text-sm break-words whitespace-pre-wrap">{agentAnswer.text}</p></div>
  {/if}
{:else}
  <ErrorBanner errors={submission.errors} />
  <div class="mt-4 flex flex-wrap items-center gap-3">
    <Button busy={(submission.busy() || drafting) && 'Drafting…'} onclick={ask}>Draft a reply</Button>
    {#if draftReply?.status === ReplyDraftStatus.Failed}
      <p class="dg-muted text-sm" data-testid="draft-reply-failed">{draftReply.why ?? 'No draft came.'}</p>
    {/if}
  </div>
  {#if alwaysCompose && canPost}
    <h2 class="dg-label mt-6 mb-2">Reply</h2>
    <Compose {replyTo} placeholder="Reply as yourself" {onposted} />
  {/if}
{/if}
