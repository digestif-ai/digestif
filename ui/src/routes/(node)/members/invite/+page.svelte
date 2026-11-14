<script lang="ts">
  import { goto } from '$app/navigation';
  import { CircleApprovalKind, MemberRole, type CircleApproval } from '#generated/ai-digestif-digestif-node.ts';
  import { createClient } from '#lib/api/client.ts';
  import { inviteEmail, regreet } from '#lib/approvals.ts';
  import Button from '#lib/components/Button.svelte';
  import ErrorBanner from '#lib/components/ErrorBanner.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import { href } from '#lib/href.ts';
  import { Submission } from '#lib/submission.svelte.ts';
  import type { PageData } from './$types';

  // Invite (DES-85466, members-invite): an email the admin writes. Every word but the two marked lines,
  // the install command and the expiry the node fills when it sends, is theirs to change; every admin
  // signs those exact words, and only the last signature sends it. Ask the admins files the approval and
  // opens its Inbox item, where the starter signs like every other admin.
  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const start = inviteEmail({ to: data.to, sender: data.sender, message: data.message });

  let to = $state(data.to);
  let role = $state<MemberRole>(data.role === 'admin' ? MemberRole.Admin : MemberRole.Member);
  let subject = $state(start.subject);
  let body = $state(start.body);
  /** Typing the To greets the guest by name; the rest of the body stays as the admin wrote it. */
  function retarget(): void {
    body = regreet(body, to, data.sender);
  }

  const client = createClient();
  const submission = new Submission();
  const FIELDS = ['to', 'role', 'email_subject', 'email_body'];

  async function ask(): Promise<void> {
    await submission.run(
      () => client.startApproval({ kind: CircleApprovalKind.Invite, to, role, email_subject: subject, email_body: body }),
      (a: CircleApproval) => goto(a.item === undefined ? href.members() : href.item(a.item), { invalidateAll: true })
    );
  }
</script>

<PageHeader title="Invite" crumbs={[{ label: 'Members', href: href.members() }]} />

<form
  class="dg-card p-4"
  aria-label="Invite"
  onsubmit={(e) => {
    e.preventDefault();
    void ask();
  }}
>
  <ErrorBanner errors={submission.generalErrors(FIELDS)} />
  {#snippet fieldError(name: string)}
    {#if submission.fieldError(name)}<span class="mt-1 block text-sm text-red-700 dark:text-red-300">{submission.fieldError(name)}</span
      >{/if}
  {/snippet}
  <label class="mb-4 block">
    <span class="dg-label mb-1 block">To</span>
    <input class="dg-input" type="text" autocomplete="off" bind:value={to} oninput={retarget} />
    {@render fieldError('to')}
  </label>
  <label class="mb-4 block">
    <span class="dg-label mb-1 block">Role</span>
    <select class="dg-input" bind:value={role}>
      <option value={MemberRole.Member}>Member</option>
      <option value={MemberRole.Admin}>Admin</option>
    </select>
    {@render fieldError('role')}
  </label>
  <label class="mb-4 block">
    <span class="dg-label mb-1 block">Subject</span>
    <input class="dg-input" type="text" bind:value={subject} />
    {@render fieldError('email_subject')}
  </label>
  <label class="mb-4 block">
    <span class="dg-label mb-1 block">Body</span>
    <textarea class="dg-input min-h-96 font-[inherit]" bind:value={body}></textarea>
    {@render fieldError('email_body')}
  </label>
  <div class="flex flex-wrap justify-end gap-2">
    <Button href={href.members()}>Cancel</Button>
    <Button variant="primary" type="submit" busy={submission.pending() && 'Asking…'} disabled={submission.busy()}>Ask the admins</Button>
  </div>
</form>
