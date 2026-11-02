import { createClient } from '#lib/api/client.ts';
import { loaded, unwrap } from '#lib/load.ts';
import { phonesOf } from '#lib/phones.ts';
import type { PageLoad } from './$types';

/** Everything the member set, one section each. Learnings and Approval render their own errors. */
export const load: PageLoad = async ({ fetch }) => {
  const client = createClient(fetch);
  const [sources, brief, rules, learnings, approval, noteTime, members] = await Promise.all([
    client.sources(),
    client.brief(),
    client.rules(),
    client.learnings(),
    client.approvalSetting(),
    client.noteTime(),
    client.members()
  ]);
  const self = unwrap(members).find((m) => m.is_self);
  const member = self === undefined ? undefined : unwrap(await client.member(self.identity));
  return {
    sources: unwrap(sources),
    brief: unwrap(brief),
    rules: unwrap(rules),
    learnings: loaded(learnings),
    approval: loaded(approval),
    noteTime: unwrap(noteTime),
    phones: phonesOf(member?.devices ?? [])
  };
};
