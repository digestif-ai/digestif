<script lang="ts">
  import PageHeader from '#lib/components/PageHeader.svelte';
  import SettingsSection from '#lib/components/SettingsSection.svelte';
  import SourceSummary from '#lib/components/SourceSummary.svelte';
  import { alwaysOn } from '#lib/always-on.ts';
  import { approvalSetting, noteTime, relativeTime, shortKey } from '#lib/format.ts';
  import { href } from '#lib/href.ts';
  import type { PageData } from './$types';

  interface Props {
    data: PageData;
  }

  let { data }: Props = $props();
  const status = $derived(data.status);
  const selected = $derived(data.sources.filter((s) => s.selected));
</script>

<PageHeader title="Settings" />

<SettingsSection title="Names" change={href.namesEdit()} testid="settings-names">
  <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
    <dt class="dg-muted">You</dt>
    <dd>{status.member_name ?? 'None'}</dd>
    <dt class="dg-muted">Your agent</dt>
    <dd>{status.agent_name ?? 'None'}</dd>
  </dl>
</SettingsSection>

<SettingsSection title="Agent" change={href.agentEdit()} testid="settings-agent">
  {#if 'errors' in data.agent}
    <p class="text-sm text-red-700 dark:text-red-300">{data.agent.errors.map((e) => e.message).join(' ')}</p>
  {:else if data.agent.data === undefined}
    <p class="dg-muted text-sm">None</p>
  {:else}
    <p class="text-sm">{data.agent.data.name}</p>
    <p class="dg-muted mt-1 font-mono text-xs break-all">{data.agent.data.path}</p>
  {/if}
</SettingsSection>

<SettingsSection title="Inbox agent" change={href.inboxAgent()} testid="settings-inbox-agent">
  {#if 'errors' in data.inboxAgent}
    <p class="text-sm text-red-700 dark:text-red-300">{data.inboxAgent.errors.map((e) => e.message).join(' ')}</p>
  {:else if data.inboxAgent.data === undefined}
    <p class="dg-muted text-sm">None</p>
  {:else}
    <p class="text-sm">{data.inboxAgent.data.is_default ? 'The default prompt' : 'Your own prompt'}</p>
    <p class="dg-muted mt-1 text-xs">
      {data.inboxAgent.data.reviewed}
      {data.inboxAgent.data.reviewed === 1 ? 'message' : 'messages'} reviewed
    </p>
    {#if data.inboxAgent.data.cannot_run}
      <p class="mt-1 text-xs text-amber-800 dark:text-amber-300" data-testid="settings-inbox-agent-cannot-run">
        {data.inboxAgent.data.cannot_run}
      </p>
    {/if}
  {/if}
</SettingsSection>

<SettingsSection title="Sources" change={href.sourcesEdit()} testid="settings-sources">
  <ul class="dg-rows -m-4" aria-label="Chosen sources">
    {#each selected as source (source.id)}
      <li class="flex px-4 py-3"><SourceSummary {source} /></li>
    {:else}
      <li class="dg-muted px-4 py-3 text-sm">None</li>
    {/each}
  </ul>
</SettingsSection>

<SettingsSection title="Repositories" change={href.settingsRepositories()} testid="settings-repositories">
  <p class="dg-muted text-sm">Organizations, repositories and commit authors</p>
</SettingsSection>

<SettingsSection title="Brief" change={href.briefEdit()} testid="settings-brief">
  {#if data.brief.text === ''}
    <p class="dg-muted text-sm">None</p>
  {:else}
    <p class="text-sm whitespace-pre-wrap" data-testid="brief-text">{data.brief.text}</p>
    {#if data.brief.updated_at}<p class="dg-muted mt-3 text-xs">Updated {relativeTime(data.brief.updated_at)}</p>{/if}
  {/if}
</SettingsSection>

<SettingsSection title="Always on" testid="always-on-rule">
  <h3 class="mb-2 font-medium">{alwaysOn.title}</h3>
  {#each alwaysOn.paragraphs as paragraph (paragraph)}
    <p class="mt-2 text-sm">{paragraph}</p>
  {/each}
</SettingsSection>

<SettingsSection title="Rules" change={href.rulesEdit()} testid="settings-rules">
  {#if data.rules.text === ''}
    <p class="dg-muted text-sm">None</p>
  {:else}
    <p class="text-sm whitespace-pre-wrap" data-testid="rules-text">{data.rules.text}</p>
    {#if data.rules.updated_at}<p class="dg-muted mt-3 text-xs">Updated {relativeTime(data.rules.updated_at)}</p>{/if}
  {/if}
</SettingsSection>

<SettingsSection title="Note prompt" change={href.notePrompt()} testid="settings-note-prompt">
  {#if 'errors' in data.notePrompt}
    <p class="text-sm text-red-700 dark:text-red-300">{data.notePrompt.errors.map((e) => e.message).join(' ')}</p>
  {:else}
    {@const np = data.notePrompt.data}
    {#if np.adoption === undefined}
      <p class="text-sm">The release's prompt</p>
    {:else}
      <p class="text-sm">{np.adoption.author.name}'s suggestion: {np.adoption.change}</p>
      <p class="dg-muted mt-1 text-xs">Adopted {relativeTime(np.adoption.at)}</p>
    {/if}
    {#if np.running !== undefined}
      <p class="dg-muted mt-1 text-xs" data-testid="note-prompt-running">
        Your notes judge {np.running.author.name}'s suggestion: {np.running.change}
      </p>
    {/if}
  {/if}
</SettingsSection>

<SettingsSection title="Learnings" change={href.learningsEdit()} testid="settings-learnings">
  {#if 'errors' in data.learnings}
    <p class="text-sm text-red-700 dark:text-red-300">{data.learnings.errors.map((e) => e.message).join(' ')}</p>
  {:else if data.learnings.data.text === ''}
    <p class="dg-muted text-sm">None</p>
  {:else}
    <p class="text-sm whitespace-pre-wrap" data-testid="learnings-text">{data.learnings.data.text}</p>
    {#if data.learnings.data.updated_at}<p class="dg-muted mt-3 text-xs">Updated {relativeTime(data.learnings.data.updated_at)}</p>{/if}
  {/if}
</SettingsSection>

<SettingsSection title="Deny list" change={href.denyList()} testid="settings-deny">
  {#if data.rules.deny.length === 0}
    <p class="dg-muted text-sm">None</p>
  {:else}
    <ul class="flex flex-wrap gap-2" aria-label="Deny list">
      {#each data.rules.deny as entry (entry.id)}
        <li class="rounded-md bg-stone-100 px-2 py-1 font-mono text-xs break-all dark:bg-stone-800">{entry.value}</li>
      {/each}
    </ul>
  {/if}
</SettingsSection>

<SettingsSection title="Approval" change={href.approvalEdit()} testid="settings-approval">
  {#if 'errors' in data.approval}
    <p class="text-sm text-red-700 dark:text-red-300">{data.approval.errors.map((e) => e.message).join(' ')}</p>
  {:else}
    <p class="text-sm">{approvalSetting(data.approval.data.setting)}</p>
  {/if}
</SettingsSection>

<SettingsSection title="Note time" change={href.noteTimeEdit()} testid="settings-note-time">
  <p class="text-sm">{noteTime(data.noteTime.time)} <span class="dg-muted">{data.noteTime.time_zone}</span></p>
</SettingsSection>

<SettingsSection title="Digest" change={href.digestEdit()} testid="settings-digest">
  <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
    <dt class="dg-muted">Email</dt>
    <dd class="break-all">{data.digest.email ?? 'None'}</dd>
    <dt class="dg-muted">After</dt>
    <dd>{noteTime(String(data.digest.hour) + ':00')}</dd>
  </dl>
</SettingsSection>

<SettingsSection title="Quiet hours" change={href.quietHours()} testid="quiet-hours">
  {#if data.rules.quiet_hours}
    <p class="text-sm">{data.rules.quiet_hours.start} to {data.rules.quiet_hours.end}</p>
    {#if data.rules.quiet_hours.active && data.rules.quiet_hours.ends_at}
      <p class="dg-muted mt-1 text-xs">Quiet now, ends {relativeTime(data.rules.quiet_hours.ends_at)}</p>
    {/if}
  {:else}
    <p class="dg-muted text-sm">None</p>
  {/if}
</SettingsSection>

<SettingsSection title="Phones" change={href.phones()} testid="settings-phones">
  {#if data.phones.length === 0}
    <p class="dg-muted text-sm">None</p>
  {:else}
    <ul class="text-sm">
      {#each data.phones as phone (phone.key)}
        <li class="py-1">
          <span class="font-mono text-xs">{shortKey(phone.key)}</span>
          <span class="dg-muted">· {phone.revoked_at ? 'removed' : 'added ' + relativeTime(phone.admitted_at)}</span>
        </li>
      {/each}
    </ul>
  {/if}
</SettingsSection>
