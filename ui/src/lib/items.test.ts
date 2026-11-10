import { ItemKind, ItemStatus, ItemSubject, Voice, type Item } from '#generated/com-bryzek-digestif-node.ts';
import { describe, expect, it } from 'vitest';
import { closedOn, itemActions, itemFrom, itemKind, itemSender, itemStatus, itemTo, newItemForm, reviewParts } from './items.ts';

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
      { text: 'https://example.com/a/b', href: 'https://example.com/a/b' },
      { text: '. Done' }
    ]);
    expect(reviewParts('Nothing to link')).toEqual([{ text: 'Nothing to link' }]);
  });
});
