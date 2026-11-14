<script lang="ts">
  import { CircleApprovalKind, CircleApprovalState, type CircleApproval } from '#generated/ai-digestif-digestif-node.ts';
  import { ADMIN_ROLE, KEY_FROM_1PASSWORD, approveCommand, promotionSteps } from '../approvals.ts';
  import { clockTime, shortKey } from '../format.ts';
  import CommandBlock from './CommandBlock.svelte';
  import StatusBadge from './StatusBadge.svelte';

  // An approval as its Inbox item shows it (DES-85466, inbox-approval and inbox-promotion): what it
  // names, the command that signs it, and every signature it needs. There is no Sign button and no key
  // field: the signature is digestif-update approve's, made where the release key is.
  interface Props {
    approval: CircleApproval;
    self: string | undefined;
  }

  let { approval, self }: Props = $props();
  const waiting = $derived(approval.state === CircleApprovalState.Waiting);
  const mine = $derived(approval.signers.find((s) => s.member?.identity === self));
  /** The promoted member, or a key's holder replacing it, signs first and makes the key the steps name. */
  const newKeyHolder = $derived(
    (approval.kind === CircleApprovalKind.Promotion || approval.kind === CircleApprovalKind.Replacement) &&
      approval.member?.identity === self
  );
  const keyless = $derived(approval.kind === CircleApprovalKind.Promotion && approval.added_key === undefined);
  /** An admin's command waits until a promoted member's key exists; their badge reads Waiting on that member meanwhile. */
  const mustSign = $derived(
    waiting && !(keyless && !newKeyHolder) && (approval.waiting_on.some((m) => m.identity === self) || (mine !== undefined && !mine.signed))
  );
  const you = (identity: string | undefined): string => (identity === self ? ' (you)' : '');
</script>

{#snippet sign()}
  {#if mustSign}
    <div class="mb-4">
      {#if newKeyHolder && keyless}
        <CommandBlock label="Sign" command={promotionSteps(approval.id)} />
        <p class="mt-2 text-sm"><a class="dg-link" href={KEY_FROM_1PASSWORD}>Keep it in 1Password instead</a></p>
      {:else}
        <CommandBlock label="Sign" command={approveCommand(approval.id)} />
      {/if}
    </div>
  {/if}
{/snippet}

{#if approval.kind === CircleApprovalKind.Invite}
  {@render sign()}
  <section class="dg-card p-4" data-testid="approval-facts">
    <dl class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1 text-sm">
      <dt class="dg-muted">To</dt>
      <dd class="break-words">{approval.guest ?? ''}</dd>
      <dt class="dg-muted">Role</dt>
      <dd>{approval.role === 'admin' ? 'Admin' : 'Member'}</dd>
      <dt class="dg-muted">Subject</dt>
      <dd class="break-words">{approval.email_subject ?? ''}</dd>
    </dl>
  </section>
  <h2 class="dg-label mt-6 mb-2">Body</h2>
  <section class="dg-card p-4">
    <p
      class="border-l-[3px] border-stone-200 pl-3 text-sm break-words whitespace-pre-wrap dark:border-stone-700"
      data-testid="approval-body"
    >
      {approval.email_body ?? ''}
    </p>
  </section>
{:else}
  <section class="dg-card mb-4 p-4" data-testid="approval-facts">
    <dl class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1 text-sm">
      <dt class="dg-muted">Member</dt>
      <dd>{approval.member?.name ?? ''}{you(approval.member?.identity)}</dd>
      {#if approval.kind === CircleApprovalKind.Promotion}
        <dt class="dg-muted">Role</dt>
        <dd>{ADMIN_ROLE}</dd>
      {:else if approval.kind === CircleApprovalKind.Removal}
        <dt class="dg-muted">Role</dt>
        <dd>Member: stays in the circle and signs nothing</dd>
      {/if}
      {#if approval.removed_key}
        <dt class="dg-muted">Key removed</dt>
        <dd class="font-mono text-xs break-all">{approval.removed_key}</dd>
      {/if}
      {#if approval.kind !== CircleApprovalKind.Removal}
        <dt class="dg-muted">{newKeyHolder ? 'Your release key' : 'Key added'}</dt>
        <dd class={approval.added_key ? 'font-mono text-xs break-all' : ''} data-testid="approval-added-key">
          {approval.added_key ?? 'None yet'}
        </dd>
      {/if}
    </dl>
  </section>
  {@render sign()}
{/if}

<h2 class="dg-label mt-6 mb-2">Signatures</h2>
<div class="dg-card overflow-hidden">
  <table class="w-full text-left text-sm" aria-label="Signatures">
    <thead class="dg-muted text-xs">
      <tr>
        <th scope="col" class="px-3 py-2 font-medium">Admin</th>
        <th scope="col" class="px-3 py-2 font-medium">Signature</th>
        <th scope="col" class="px-3 py-2 font-medium">When</th>
      </tr>
    </thead>
    <tbody>
      {#each approval.signers as signer (signer.key)}
        <tr class="border-t border-stone-200 dark:border-stone-800" data-testid="signature-row">
          <td class="px-3 py-2">
            {#if signer.member}{signer.member.name}{you(signer.member.identity)}{:else}<span class="font-mono text-xs"
                >{shortKey(signer.key)}</span
              >{/if}
          </td>
          <td class="px-3 py-2">
            <StatusBadge status={signer.signed ? { label: 'Signed', tone: 'good' } : { label: 'Not yet', tone: 'warn' }} />
          </td>
          <td class="dg-muted px-3 py-2 text-xs">{signer.signed_at ? clockTime(signer.signed_at) : ''}</td>
        </tr>
      {/each}
    </tbody>
  </table>
</div>
