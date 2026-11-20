import { createClient } from '#lib/api/client.ts';
import { loaded, selfOf, unwrap } from '#lib/load.ts';
import { phonesOf } from '#lib/phones.ts';
import type { PageLoad } from './$types';

/** Everything the member set, one section each. Learnings, Approval, the agent, the Inbox agent and the note prompt render their own errors. */
export const load: PageLoad = async ({ fetch, parent }) => {
  const client = createClient(fetch);
  const status = parent().then((p) => p.status);
  const [sources, brief, rules, learnings, approval, noteTime, digest, member, agent, notePrompt, inboxAgent] = await Promise.all([
    client.sources(),
    client.brief(),
    client.rules(),
    client.learnings(),
    client.approvalSetting(),
    client.noteTime(),
    client.digestSettings(),
    selfOf(client),
    client.agent(),
    client.notePrompt(),
    client.inboxAgent()
  ]);
  return {
    status: await status,
    sources: unwrap(sources),
    brief: unwrap(brief),
    rules: unwrap(rules),
    learnings: loaded(learnings),
    approval: loaded(approval),
    noteTime: unwrap(noteTime),
    digest: unwrap(digest),
    notePrompt: loaded(notePrompt),
    /** No agent saved is a 404: the section reads None. */
    agent: agent.status === 404 ? { data: undefined } : loaded(agent),
    /** A node with no agent has no Inbox agent: a 404, and the section reads None. */
    inboxAgent: inboxAgent.status === 404 ? { data: undefined } : loaded(inboxAgent),
    phones: phonesOf(member?.devices ?? [])
  };
};
