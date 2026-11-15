import {
  ItemAgentAskStatus,
  ItemDone,
  ItemKind,
  ItemState,
  ItemStatus,
  ItemSubject,
  ItemWaitingAct,
  ItemWaitingOn,
  Voice,
  type Item
} from '#generated/ai-digestif-digestif-node.ts';
import { describe, expect, it } from 'vitest';
import {
  checkedKinds,
  inboxView,
  isUnread,
  waitingText,
  agentAskText,
  agentHandoff,
  closedOn,
  itemActions,
  itemFrom,
  itemFromParts,
  itemKind,
  itemSender,
  itemStatus,
  itemTo,
  kindQuery,
  newItemForm,
  noticeActions,
  onlyMine,
  reviewParts,
  toggledKind
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
    expect(itemStatus(ItemStatus.Read).tone).toBe('neutral');
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
    expect(itemFrom(item({ voice: Voice.Agent }), me.identity)).toBe('from Juno');
    expect(itemFromParts(item({ voice: Voice.Agent }), me.identity)).toEqual({ lead: 'from', agent: ben });
    expect(itemFrom(item({ voice: Voice.Agent, author: me, status: ItemStatus.Draft }), me.identity)).toBe('drafted by Hermes');
    expect(itemFrom(item({ voice: Voice.Agent, author: me }), me.identity)).toBe('from Hermes');
    expect(itemFrom(item({ author: me }), me.identity)).toBe('from you');
    expect(itemFrom(item({ voice: Voice.Node, author: me }), me.identity)).toBe('from your node');
  });

  it("names the Inbox row's sender: you, your agent or node, or the member or their agent (ISS-64736)", () => {
    expect(itemSender(item({}), me.identity)).toBe('Ben Ortiz');
    expect(itemSender(item({ voice: Voice.Agent }), me.identity)).toBe('Juno');
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
  it('offers Answer on an open question the member did not ask', () => {
    const a = itemActions(item({}), me.identity);
    expect([a.answer, a.close, a.draft]).toEqual([true, false, false]);
    expect(itemActions(item({ closed: true }), me.identity).answer).toBe(false);
  });

  it('offers no answer on a closed question, and still a reply on a closed notice or choice (DIG-538)', () => {
    const question = itemActions(item({ closed: true }), me.identity);
    expect([question.answer, question.reply]).toEqual([false, false]);
    expect(itemActions(item({ kind: ItemKind.Notice, closed: true }), me.identity).reply).toBe(true);
    expect(itemActions(item({ kind: ItemKind.Choice, closed: true }), me.identity).reply).toBe(true);
  });

  it('lets the asker close or reopen their own question', () => {
    const a = itemActions(item({ author: me, status: ItemStatus.Read }), me.identity);
    expect([a.close, a.answer]).toEqual([true, false]);
  });

  it('makes a draft Send, Edit and Discard and nothing else', () => {
    const a = itemActions(item({ author: me, voice: Voice.Agent, status: ItemStatus.Draft, kind: ItemKind.Notice }), me.identity);
    expect([a.draft, a.archive, a.unread, a.reply, a.close]).toEqual([true, false, false, false, false]);
  });

  it('takes one pick on an open choice', () => {
    const choice = item({ kind: ItemKind.Choice, options: [{ id: 'a', label: 'A', recommended: true }] });
    expect(itemActions(choice, me.identity).pick).toBe(true);
    expect(itemActions({ ...choice, picks: [{ member: me, option_id: 'a', picked_at: '' }] }, me.identity).pick).toBe(false);
  });

  it('archives anything sent, and marks a read item unread (ISS-88476)', () => {
    expect(itemActions(item({ status: ItemStatus.New }), me.identity)).toMatchObject({ archive: true, unread: false });
    expect(itemActions(item({ status: ItemStatus.Read }), me.identity)).toMatchObject({ archive: true, unread: true });
  });

  it('marks a Send invite notice sent until it is settled (ISS-88004)', () => {
    const invite = item({ kind: ItemKind.Notice, subject: ItemSubject.SendInvite, voice: Voice.Node, author: me });
    expect(itemActions(invite, me.identity).markSent).toBe(true);
    expect(itemActions({ ...invite, done: ItemDone.Acknowledged }, me.identity).markSent).toBe(false);
    expect(itemActions(item({ kind: ItemKind.Notice }), me.identity).markSent).toBe(false);
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
    expect(reviewParts('http://localhost:5173/feed/new')).toEqual([{ text: '/feed/new', href: '/feed/new' }]);
    expect(reviewParts('https://example.com/feed/sha256:ab')).toEqual([
      { text: 'example.com/feed/sha256:ab', href: 'https://example.com/feed/sha256:ab' }
    ]);
  });
  it('opens any other node page on the page origin, and leaves it as text on the phone (ISS-86952)', () => {
    const line = 'See http://127.0.0.1:7420/inbox/itm-42?tab=replies#r3 for it';
    expect(reviewParts(line)).toEqual([
      { text: 'See ' },
      { text: '/inbox/itm-42?tab=replies#r3', href: '/inbox/itm-42?tab=replies#r3' },
      { text: ' for it' }
    ]);
    expect(reviewParts(line, { node: false })).toEqual([{ text: 'See ' }, { text: '/inbox/itm-42?tab=replies#r3' }, { text: ' for it' }]);
    expect(reviewParts('http://[::1]:7420/settings/repositories/edit', { node: false })).toEqual([{ text: '/settings/repositories/edit' }]);
  });
});

describe('the Inbox view and kind checks (DIG-476, ISS-88476)', () => {
  it('opens on the Inbox itself, and reads the one view named', () => {
    expect(inboxView(new URLSearchParams(''))).toBeUndefined();
    expect(inboxView(new URLSearchParams('state=archived'))).toBe(ItemState.Archived);
    expect(inboxView(new URLSearchParams('state=others&state=you'))).toBe(ItemState.Others);
    expect(inboxView(new URLSearchParams('state=bogus'))).toBeUndefined();
  });
  it('toggles one kind, keeping the others', () => {
    expect(checkedKinds(new URLSearchParams('kind=Notice&kind=Nope&kind=Question'))).toEqual(['Question', 'Notice']);
    expect(toggledKind(['Notice'], 'Question')).toEqual(['Question', 'Notice']);
    expect(toggledKind(['Notice'], 'Notice')).toEqual([]);
  });
  it('names the kinds and subjects the node filters by for each kind checked (ISS-86956)', () => {
    expect(kindQuery(['Question'])).toEqual({ kinds: [ItemKind.Question], subjects: [ItemSubject.NoteQuestion] });
    expect(kindQuery(['Intro', 'Choice'])).toEqual({ kinds: [ItemKind.Choice], subjects: [ItemSubject.Intro] });
    expect(kindQuery(['Notice']).subjects).toContain(ItemSubject.NoteReady);
    expect(kindQuery([])).toEqual({ kinds: [], subjects: [] });
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

  it('opens the page on the machine', () => {
    const a = noticeActions(notice(), here);
    expect(a.open).toEqual({ label: 'Open on your machine', href: '/settings/repositories/edit' });
    expect(a.address).toBeUndefined();
  });
  it("shows the label and the node's own address as text away from the machine", () => {
    const a = noticeActions(notice(), { ...here, hostname: '192.168.1.20' });
    expect(a.open).toBeUndefined();
    expect(a.address).toEqual({ text: 'Choose on Settings, Repositories', address: 'http://127.0.0.1:7070/settings/repositories/edit' });
  });
  it('shows no address to type when the node names none', () => {
    const { address: _address, ...rest } = notice();
    expect(noticeActions(rest, { ...here, hostname: 'digestif.example' }).address).toBeUndefined();
  });
  it('shows nothing when the notice has no page', () => {
    const { path: _page, ...rest } = notice();
    expect(noticeActions({ ...rest, subject: ItemSubject.Work, local: false }, here)).toEqual({});
  });
  it('keeps the Open link on a settled notice, with no agent', () => {
    const done = notice({ done: ItemDone.Resolved });
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

describe('reply (DIG-477, ISS-88476)', () => {
  it('is on a notice or a choice anyone in the circle sent, and nowhere else', () => {
    for (const kind of [ItemKind.Choice, ItemKind.Notice]) {
      expect(itemActions(item({ kind, author: ben }), me.identity).reply).toBe(true);
      expect(itemActions(item({ kind, author: ben, voice: Voice.Agent }), me.identity).reply).toBe(true);
      expect(itemActions(item({ kind, author: me }), me.identity).reply).toBe(true);
    }
    expect(itemActions(item({ kind: ItemKind.Question, author: ben }), me.identity).reply).toBe(false);
    expect(itemActions(item({ author: me, voice: Voice.Node, kind: ItemKind.Notice }), me.identity).reply).toBe(false);
    expect(itemActions(item({ kind: ItemKind.Notice, author: ben, status: ItemStatus.Draft }), me.identity).reply).toBe(false);
  });
  it('is not on an item only the member reads (DIG-536)', () => {
    const toMe = { circle: false, members: [me] };
    const toBen = { circle: false, members: [ben] };
    for (const kind of [ItemKind.Choice, ItemKind.Notice]) {
      expect(itemActions(item({ kind, author: me, to: toMe }), me.identity).reply).toBe(false);
      expect(itemActions(item({ kind, author: me, to: toBen }), me.identity).reply).toBe(true);
      expect(itemActions(item({ kind, author: ben, to: toMe }), me.identity).reply).toBe(true);
    }
    expect(onlyMine(item({ author: me, to: toMe }), me.identity)).toBe(true);
    expect(onlyMine(item({ author: me, to: { circle: false, members: [me, ben] } }), me.identity)).toBe(false);
    expect(onlyMine(item({ author: me }), me.identity)).toBe(false);
  });
});

describe('the Inbox row (ISS-88476)', () => {
  it('is bold while unread or a draft', () => {
    expect([ItemStatus.New, ItemStatus.Draft, ItemStatus.Read].map((status) => isUnread({ status }))).toEqual([true, true, false]);
  });
  it('names whom it waits on', () => {
    expect(waitingText({})).toBe('');
    expect(waitingText({ waiting: { on: ItemWaitingOn.You, act: ItemWaitingAct.Answer } })).toBe('You: answer');
    expect(waitingText({ waiting: { on: ItemWaitingOn.Others, circle: true, members: [] } })).toBe('The circle');
    expect(waitingText({ waiting: { on: ItemWaitingOn.Others, circle: false, members: [ben] } })).toBe('Ben Ortiz');
    expect(waitingText({ waiting: { on: ItemWaitingOn.Others, circle: false, members: [ben, cy] } })).toBe('Ben Ortiz and 1 other');
    expect(waitingText({ waiting: { on: ItemWaitingOn.Others, circle: false, members: [ben, cy, me] } })).toBe('Ben Ortiz and 2 others');
  });
});
