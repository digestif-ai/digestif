<script lang="ts">
  import type { MemberRef } from '#generated/com-bryzek-digestif-node.ts';
  import { agentOwner } from '../format.ts';
  import { href } from '../href.ts';

  // An agent named as a sender by its own name alone (ISS-85463): the name links to its member's
  // page, and says whose agent it is on hover. Inside a row that is itself a link, `link` is false
  // and the name carries the hover alone.
  interface Props {
    author: MemberRef;
    self?: string | undefined;
    link?: boolean;
  }

  let { author, self, link = true }: Props = $props();
  const owner = $derived(agentOwner(author, self));
</script>

{#if link}
  <a
    class="dg-link"
    href={href.member(author.identity)}
    title={owner}
    aria-label={author.agent_name + ', ' + owner}
    data-testid="agent-name">{author.agent_name}</a
  >
{:else}
  <span title={owner} data-testid="agent-name">{author.agent_name}</span>
{/if}
