import { describe, expect, it } from 'vitest';
import type { ItemSummary, MemberSummary } from '#generated/com-bryzek-digestif-node.ts';
import { groupHits, itemHits, matches, memberHits, runSearch, searchHref, settingsHits, words, MAX_PAGES, PAGE_SIZE } from './search.ts';
import type { Client } from '#lib/api/client.ts';

const author = { identity: 'ed25519:a', name: 'Ben Ortiz', agent_name: 'Juno' };
const item = (id: string, title: string): ItemSummary => ({ id, title, author }) as unknown as ItemSummary;
const member = (name: string): MemberSummary => ({ identity: 'ed25519:' + name, name, agent_name: 'Hermes' }) as unknown as MemberSummary;

describe('matching', () => {
  it('needs every word, in any field, in any case', () => {
    expect(words('  Eval  SETS ')).toEqual(['eval', 'sets']);
    expect(matches('eval ben', 'Keep eval sets clean', 'Ben Ortiz')).toBe(true);
    expect(matches('eval zed', 'Keep eval sets clean', 'Ben Ortiz')).toBe(false);
    expect(matches('   ', 'anything')).toBe(false);
  });
});

describe('hits', () => {
  it('link an item, a member and a settings page to their pages', () => {
    expect(itemHits('eval', [item('i1', 'Eval sets'), item('i2', 'Relay')])).toEqual([
      { kind: 'inbox', title: 'Eval sets', detail: 'From Ben Ortiz', href: '/inbox/i1' }
    ]);
    expect(memberHits('ada', [member('Ada Park'), member('Cy Lund')]).map((h) => h.href)).toEqual(['/members/ed25519%3AAda%20Park']);
    expect(settingsHits('quiet').map((h) => h.href)).toContain('/settings/quiet-hours');
    expect(settingsHits('zzzz')).toEqual([]);
  });

  it('groups in the page order and leaves empty kinds out', () => {
    const groups = groupHits([...settingsHits('names'), ...memberHits('ben', [member('Ben Ortiz')]), ...itemHits('x', [item('1', 'x')])]);
    expect(groups.map((g) => g.kind)).toEqual(['inbox', 'members', 'settings']);
  });

  it('builds the result address', () => {
    expect(searchHref(' a b ')).toBe('/search?q=a%20b');
    expect(searchHref('  ')).toBe('/search');
  });
});

describe('runSearch', () => {
  const ok = <T>(data: T) => Promise.resolve({ data, status: 200 });
  it('reads every page of a long list, then says when it stops at the cap', async () => {
    const full = (n: number): ItemSummary[] => Array.from({ length: PAGE_SIZE }, (_, i) => item('r' + String(n) + '-' + String(i), 'row'));
    let calls = 0;
    const client = {
      items: () => ok(full(calls++)),
      feed: () => ok([]),
      notes: () => ok({ notes: [], suggest_auto_approval: false, no_activity: false }),
      members: () => ok([member('Ada Park')])
    } as unknown as Client;
    const result = await runSearch('row', client);
    expect(calls).toBe(MAX_PAGES);
    expect(result.cut).toEqual(['Inbox']);
    expect(result.groups[0]?.hits).toHaveLength(MAX_PAGES * PAGE_SIZE);
  });

  it('names a list that failed and still answers with the others', async () => {
    const client = {
      items: () => Promise.resolve({ errors: [{ code: 'x', message: 'Down.' }], status: 500 }),
      feed: () => ok([]),
      notes: () => ok({ notes: [], suggest_auto_approval: false, no_activity: false }),
      members: () => ok([member('Ada Park')])
    } as unknown as Client;
    const result = await runSearch('ada', client);
    expect(result.failed).toEqual([{ label: 'Inbox', message: 'Down.' }]);
    expect(result.groups.map((g) => g.kind)).toEqual(['members']);
  });

  it('asks nothing for a blank query', async () => {
    expect(await runSearch('  ', {} as Client)).toEqual({ groups: [], failed: [], cut: [] });
  });
});
