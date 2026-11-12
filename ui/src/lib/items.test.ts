import { ItemAgentAskStatus, ItemKind, ItemStatus, ItemSubject, Voice, type Item } from '#generated/com-bryzek-digestif-node.ts';
import { describe, expect, it } from 'vitest';
import {
  checkedStatuses,
  agentAskText,
  agentHandoff,
  closedOn,
  itemActions,
  itemFrom,
  itemKind,
  itemSender,
  itemStatus,
  itemTo,
  newItemForm,
  noticeActions,
  reviewParts,
  toggled
} from './items.ts';

const me = { identity: 'ed25519:me', name: 'Ada Park', agent_name: 'Hermes' };
const ben = { identity: 'ed25519:ben', name: 'Ben Ortiz', agent_name: 'Juno' };
const cy = { identity: 'ed25519:cy', name: 'Cy Lund', agent_name: 'Otis' };

function item(over: Partial<Item>): Item {
  return {
    id: 'itm-1',
    kind: ItemKind.Question,
    voice: Voice.Person,
    author: ben,
    to: { circle: true, members: [] },
    title: 'A question',
    detail: '',
    status: ItemStatus.New,
    closed: false,
    created_at: '2026-11-06T10:00:00.000Z',
    local: false,
    options: [],
    answers: [],
    picks: [],
    closes: [],
    ...over
  };
}

describe('item words', () => {
  it('tones only the status', () => {
    expect(itemStatus(ItemStatus.Draft)).toEqual({ label: 'Draft', tone: 'info' });
    expect(itemStatus(ItemStatus.New).tone).toBe('warn');
    expect(itemStatus(ItemStatus.Done).tone).toBe('good');
  });

  it('names the subject when there is one, else the kind', () => {
    expect(itemKind({ kind: ItemKind.Question })).toBe('Question');
    expect(itemKind({ kind: ItemKind.Notice, subject: ItemSubject.Intro })).toBe('Intro');
    expect(itemKind({ kind: ItemKind.Notice, subject: ItemSubject.Work })).toBe('Work');
    expect(itemKind({ kind: ItemKind.Notice, subject: ItemSubject.Credit })).toBe('Filed');
    expect(itemKind({ kind: ItemKind.Choice, subject: ItemSubject.Suggestion })).toBe('Prompt suggestion');
    expect(itemKind({ kind: ItemKind.Notice, subject: ItemSubject.Repositories })).toBe('Notice');
  });

  it('says who it is from', () => {
    expect(itemFrom(item({}), me.identity)).toBe('from Ben Ortiz');
    expect(itemFrom(item({ voice: Voice.Agent }), me.identity)).toBe("from Juno (Ben Ortiz's agent)");
    expect(itemFrom(item({ voice: Voice.Agent, author: me, status: ItemStatus.Draft }), me.identity)).toBe('drafted by Hermes');
    expect(itemFrom(item({ voice: Voice.Agent, author: me }), me.identity)).toBe('from Hermes');
    expect(itemFrom(item({ author: me }), me.identity)).toBe('from you');
    expect(itemFrom(item({ voice: Voice.Node, author: me }), me.identity)).toBe('from your node');
  });

  it("names the Inbox row's sender: you, your agent or node, or the member or their agent (ISS-64736)", () => {
    expect(itemSender(item({}), me.identity)).toBe('Ben Ortiz');
    expect(itemSender(item({ voice: Voice.Agent }), me.identity)).toBe("Juno (Ben Ortiz's agent)");
    expect(itemSender(item({ author: me }), me.identity)).toBe('You');
    expect(itemSender(item({ voice: Voice.Agent, author: me }), me.identity)).toBe('Hermes');
    expect(itemSender(item({ voice: Voice.Node, author: me }), me.identity)).toBe('Your node');
  });

  it('says whom it is to', () => {
    expect(itemTo(item({}), me.identity)).toBe('to the circle');
    expect(itemTo(item({ to: { circle: false, members: [me] } }), me.identity)).toBe('to you');
    expect(itemTo(item({ to: { circle: false, members: [ben, me] } }), me.identity)).toBe('to Ben Ortiz, you');
  });
});

describe('itemActions', () => {
  it('offers Answer and Not for me on an open question the member did not ask', () => {
    const a = itemActions(item({}), me.identity);
    expect([a.answer, a.notForMe, a.close, a.draft]).toEqual([true, true, false, false]);
    expect(itemActions(item({ status: ItemStatus.Done }), me.identity).notForMe).toBe(false);
    expect(itemActions(item({ closed: true }), me.identity).answer).toBe(false);
  });

  it('lets the asker close or reopen their own question, never set it aside', () => {
    const a = itemActions(item({ author: me, status: ItemStatus.Read }), me.identity);
    expect([a.close, a.answer, a.notForMe]).toEqual([true, false, false]);
  });

  it('makes a draft Send, Edit and Discard and nothing else', () => {
    const a = itemActions(item({ author: me, voice: Voice.Agent, status: ItemStatus.Draft, kind: ItemKind.Notice }), me.identity);
    expect([a.draft, a.acknowledge, a.close]).toEqual([true, false, false]);
  });

  it('takes one pick on an open choice and one Acknowledge on a notice', () => {
    const choice = item({ kind: ItemKind.Choice, options: [{ id: 'a', label: 'A', recommended: true }] });
    expect(itemActions(choice, me.identity).pick).toBe(true);
    expect(itemActions({ ...choice, picks: [{ member: me, option_id: 'a', picked_at: '' }] }, me.identity).pick).toBe(false);
    expect(itemActions(item({ kind: ItemKind.Notice }), me.identity).acknowledge).toBe(true);
    expect(itemActions(item({ kind: ItemKind.Notice, status: ItemStatus.Done }), me.identity).acknowledge).toBe(false);
  });
});

describe('closedOn', () => {
  it('finds the answer a close names', () => {
    const a = { hash: 'sha256:a', author: ben, voice: Voice.Person, text: 'x', created_at: '' };
    const close = { closed: true, voice: Voice.Agent, at: '', answer: 'sha256:a' };
    expect(closedOn(item({ answers: [a], close }))).toBe(a);
    expect(closedOn(item({ answers: [a] }))).toBeUndefined();
  });
});

describe('newItemForm', () => {
  const fields = { circle: true, members: [ben.identity], title: 'T', detail: 'D', send: true };
  it('sends a question to the circle and drops the members it does not use', () => {
    expect(newItemForm({ ...fields, kind: 'question' }, me.identity)).toEqual({
      kind: 'question',
      circle: true,
      title: 'T',
      detail: 'D',
      send: true
    });
  });

  it('makes an intro a notice to the two it introduces', () => {
    expect(newItemForm({ ...fields, kind: 'intro', members: [ben.identity, cy.identity] }, me.identity)).toEqual({
      kind: 'notice',
      subject: 'intro',
      circle: false,
      members: [ben.identity, cy.identity],
      title: 'T',
      detail: 'D',
      send: true
    });
  });

  it('makes a prompt suggestion a choice to its judges, its author among them', () => {
    const form = newItemForm({ ...fields, kind: 'suggestion', send: false }, me.identity);
    expect([form.kind, form.subject, form.circle, form.members]).toEqual(['choice', 'suggestion', false, [me.identity, ben.identity]]);
  });
});

describe('reviewParts', () => {
  it('links a URL and an owner/repo#n, and leaves the rest as text', () => {
    expect(reviewParts('Filed it as digestif-ai/digestif#312, as your prompt says.')).toEqual([
      { text: 'Filed it as ' },
      { text: 'digestif-ai/digestif#312', href: 'https://github.com/digestif-ai/digestif/issues/312' },
      { text: ', as your prompt says.' }
    ]);
    expect(reviewParts('See https://example.com/a/b. Done')).toEqual([
      { text: 'See ' },
      { text: 'example.com/a/b', href: 'https://example.com/a/b' },
      { text: '. Done' }
    ]);
    expect(reviewParts('Nothing to link')).toEqual([{ text: 'Nothing to link' }]);
  });
  it('reads a URL well: a GitHub item as owner/repo#n, the rest without its scheme (DIG-448)', () => {
    expect(reviewParts('Filed as https://github.com/gibralink/devfactory/issues/1365.')).toEqual([
      { text: 'Filed as ' },
      { text: 'gibralink/devfactory#1365', href: 'https://github.com/gibralink/devfactory/issues/1365' },
      { text: '.' }
    ]);
    expect(reviewParts('https://github.com/digestif-ai/digestif/pull/447')).toEqual([
      { text: 'digestif-ai/digestif#447', href: 'https://github.com/digestif-ai/digestif/pull/447' }
    ]);
    const long = 'https://example.com/' + 'a'.repeat(80);
    const [part] = reviewParts(long);
    expect(part).toEqual({ text: 'example.com/' + 'a'.repeat(47) + '…', href: long });
    expect(part?.text).toHaveLength(60);
  });
  it('opens a note of a node feed on the page origin, and leaves it as text on the phone (DIG-448)', () => {
    const line = 'in their note: http://127.0.0.1:7420/feed/sha256%3A20c1e21b156172ae207b9291c67ebe78. Filed';
    expect(reviewParts(line)).toEqual([
      { text: 'in their note: ' },
      { text: 'note 20c1e21b15', href: '/feed/sha256%3A20c1e21b156172ae207b9291c67ebe78' },
      { text: '. Filed' }
    ]);
    expect(reviewParts(line, { node: false })[1]).toEqual({ text: 'note 20c1e21b15' });
    expect(reviewParts('http://localhost:5173/feed/new')).toEqual([
      { text: 'localhost:5173/feed/new', href: 'http://localhost:5173/feed/new' }
    ]);
    expect(reviewParts('https://example.com/feed/sha256:ab')).toEqual([
      { text: 'example.com/feed/sha256:ab', href: 'https://example.com/feed/sha256:ab' }
    ]);
  });
});

describe('the Inbox status checks (ISS-71225)', () => {
  const D = ItemStatus.Draft,
    N = ItemStatus.New,
    R = ItemStatus.Read,
    X = ItemStatus.Done;
  it('opens with Draft, New and Read checked', () => {
    expect(checkedStatuses(new URLSearchParams(''))).toEqual([D, N, R]);
  });
  it('reads the statuses named, in order, and none when given empty', () => {
    expect(checkedStatuses(new URLSearchParams('status=done&status=draft&status=bogus'))).toEqual([D, X]);
    expect(checkedStatuses(new URLSearchParams('status='))).toEqual([]);
  });
  it('toggles one status, keeping the others', () => {
    expect(toggled([D, N, R], X)).toEqual([D, N, R, X]);
    expect(toggled([D, N, R], N)).toEqual([D, R]);
  });
});

describe('a notice that needs the member (DIG-355)', () => {
  const mine = { ...me };
  const notice = (over: Partial<Item> = {}): Item =>
    item({
      kind: ItemKind.Notice,
      subject: ItemSubject.Repositories,
      voice: Voice.Node,
      author: mine,
      title: '1 new repository waits for you on your machine.',
      detail: 'Decide whether Digestif may read it. Nothing is read until you say so.',
      local: true,
      path: '/settings/repositories/edit',
      address: 'http://127.0.0.1:7070/settings/repositories/edit',
      ...over
    });
  const here = { self: me.identity, hostname: '127.0.0.1', agentConnected: true };

  it('opens the page on the machine as the primary action, with Acknowledge second', () => {
    const a = noticeActions(notice(), here);
    expect(a.open).toEqual({ label: 'Open on your machine', href: '/settings/repositories/edit' });
    expect(a.address).toBeUndefined();
    expect(a.acknowledge).toBe('secondary');
  });
  it("shows the label and the node's own address as text away from the machine, Acknowledge staying primary", () => {
    const a = noticeActions(notice(), { ...here, hostname: '192.168.1.20' });
    expect(a.open).toBeUndefined();
    expect(a.address).toEqual({ text: 'Choose on Settings, Repositories', address: 'http://127.0.0.1:7070/settings/repositories/edit' });
    expect(a.acknowledge).toBe('primary');
  });
  it('shows no address to type when the node names none', () => {
    const { address: _address, ...rest } = notice();
    expect(noticeActions(rest, { ...here, hostname: 'digestif.example' }).address).toBeUndefined();
  });
  it('shows Acknowledge alone when the notice has no page', () => {
    const { path: _page, ...rest } = notice();
    expect(noticeActions({ ...rest, subject: ItemSubject.Work, local: false }, here)).toEqual({ acknowledge: 'primary' });
  });
  it('keeps the Open link on a Done notice, with no Acknowledge and no agent', () => {
    const done = notice({ status: ItemStatus.Done });
    expect(noticeActions(done, here)).toEqual({ open: { label: 'Open on your machine', href: '/settings/repositories/edit' } });
    expect(noticeActions(done, { ...here, hostname: '192.168.1.20' }).address).toBeDefined();
  });
  it("offers Ask your agent on the member's own node's notice when an agent is connected, a connect hint when none is", () => {
    expect(noticeActions(notice(), here).agent).toEqual({ action: 'ask', label: 'Ask your agent', disabled: false });
    expect(noticeActions(notice(), { ...here, agentConnected: false }).agent).toEqual({
      action: 'connect',
      label: 'Connect an agent',
      href: '/settings/agent'
    });
  });
  it('offers the agent on a notice with a page away from the machine too, since the agent runs on the node', () => {
    expect(noticeActions(notice(), { ...here, hostname: '192.168.1.20' }).agent?.action).toBe('ask');
  });
  it('offers no agent on a notice with no page, since there is nothing to open', () => {
    const { path: _page, ...rest } = notice();
    expect(noticeActions({ ...rest, subject: ItemSubject.Work, local: false }, here).agent).toBeUndefined();
  });
  it('says where an ask stands', () => {
    const at = '2026-11-10T10:00:00.000Z';
    expect(agentAskText(notice())).toBeUndefined();
    expect(agentAskText(notice({ agent_ask: { status: ItemAgentAskStatus.Asked, at } }))).toBe(
      'Asked. The answer arrives as a reply on this notice.'
    );
    expect(agentAskText(notice({ agent_ask: { status: ItemAgentAskStatus.Answered, at, reply: 'Done.' } }))).toBe('Your agent answered.');
    expect(agentAskText(notice({ agent_ask: { status: ItemAgentAskStatus.Failed, at } }))).toBeUndefined();
  });
  it('disables Ask your agent while an ask waits and enables it again once it settled', () => {
    const at = '2026-11-10T10:00:00.000Z';
    const ask = (status: ItemAgentAskStatus) => noticeActions(notice({ agent_ask: { status, at } }), here).agent;
    expect(ask(ItemAgentAskStatus.Asked)).toEqual({ action: 'ask', label: 'Ask your agent', disabled: true });
    expect(ask(ItemAgentAskStatus.Answered)).toMatchObject({ disabled: false });
    expect(ask(ItemAgentAskStatus.Failed)).toMatchObject({ disabled: false });
  });
  it('offers no Open and no agent on a notice from someone else', () => {
    const a = noticeActions(notice({ author: ben }), here);
    expect(a.open).toBeUndefined();
    expect(a.agent).toBeUndefined();
  });
  it('keeps a plain link for an item that is not such a notice', () => {
    const suggestion = item({ kind: ItemKind.Choice, subject: ItemSubject.Suggestion, path: '/feed/n1' });
    expect(noticeActions(suggestion, here)).toEqual({ link: { text: "Pick tonight's version on your waiting note", href: '/feed/n1' } });
  });
  it('hands the agent nothing when there is no page', () => {
    const { path: _page, ...rest } = notice();
    expect(agentHandoff(rest)).toBeUndefined();
  });
  it('hands the agent the item id, the kind, the title and the page, and nothing else', () => {
    const secret = notice({ detail: 'repo acme/secret at /Users/ada/secret failed: model_unavailable', about: 'sha256:abc' });
    const h = agentHandoff(secret);
    expect(h).toEqual({ item: 'itm-1', kind: 'notice', title: secret.title, page: '/settings/repositories/edit' });
    expect(JSON.stringify(h)).not.toMatch(/secret|model_unavailable|\/Users/);
  });
});
