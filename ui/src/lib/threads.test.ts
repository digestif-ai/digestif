import {
  ItemKind,
  ItemStatus,
  MessageStatus,
  StatusNote,
  Voice,
  type FeedItem,
  type ItemSummary
} from '#generated/com-bryzek-digestif-node.ts';
import { describe, expect, it } from 'vitest';
import { feedThreads, itemThreads, threadsOf } from './threads.ts';

const roman = { identity: 'ed25519:roman', name: 'Roman Cherkasov', agent_name: 'Juno' };
const ben = { identity: 'ed25519:ben', name: 'Ben Ortiz', agent_name: 'Otis' };

function message(hash: string, day: number, over: Partial<FeedItem> = {}): FeedItem {
  return {
    hash,
    kind: 'summary',
    voice: Voice.Agent,
    author: roman,
    created_at: `2026-11-${String(day).padStart(2, '0')}T21:00:00.000Z`,
    status: MessageStatus.Posted,
    preview: hash,
    ...over
  };
}

const waiting = (hash: string, day: number, author = roman): FeedItem =>
  message(hash, day, { author, status_note: StatusNote.WaitingForApproval, status_note_words: 'No note today' });

/** The threads as [key, hashes oldest first], newest thread first, the way the Feed reads them. */
const shape = (feed: FeedItem[]): [string, string[]][] => feedThreads(feed).map((t) => [t.key, t.rows.map((m) => m.hash)]);

describe('threadsOf', () => {
  it('shows each thread once at its latest row and keeps every row oldest first', () => {
    const rows = [
      { id: 'c', k: 'x', created_at: '3' },
      { id: 'b', k: 'y', created_at: '2' },
      { id: 'a', k: 'x', created_at: '1' }
    ];
    const threads = threadsOf(rows, (r) => r.k);
    expect(threads.map((t) => t.shown.id)).toEqual(['c', 'b']);
    expect(threads[0]!.rows.map((r) => r.id)).toEqual(['a', 'c']);
  });

  it('shows the first row in the list order, and keeps every row in the order written', () => {
    // The Inbox's order: a New item first, though older than the Read one in its thread.
    const rows = [
      { id: 'new', k: 'x', created_at: '1' },
      { id: 'other', k: 'y', created_at: '5' },
      { id: 'read', k: 'x', created_at: '3' }
    ];
    const threads = threadsOf(rows, (r) => r.k);
    expect(threads.map((t) => [t.key, t.shown.id, t.rows.map((r) => r.id)])).toEqual([
      ['x', 'new', ['new', 'read']],
      ['y', 'other', ['other']]
    ]);
  });
});

describe('feedThreads', () => {
  it('joins the waiting-for-approval status note to the note that then goes out', () => {
    expect(shape([message('note', 13), waiting('wait', 12)])).toEqual([['note', ['wait', 'note']]]);
  });

  it('joins several days of waiting to the one note', () => {
    expect(shape([message('note', 14), waiting('w2', 13), waiting('w1', 12)])).toEqual([['note', ['w1', 'w2', 'note']]]);
  });

  it('keeps a wait with no note yet as a thread of its own', () => {
    expect(shape([waiting('w2', 13), waiting('w1', 12), message('old', 11)])).toEqual([
      ['w1', ['w1', 'w2']],
      ['old', ['old']]
    ]);
  });

  it('joins only the same author', () => {
    expect(shape([message('ben-note', 13, { author: ben }), waiting('wait', 12)])).toEqual([
      ['ben-note', ['ben-note']],
      ['wait', ['wait']]
    ]);
  });

  it('ends a wait at another status note from the author', () => {
    expect(shape([message('note', 14), message('could-not', 13, { status_note: StatusNote.CouldNotRun }), waiting('wait', 12)])).toEqual([
      ['note', ['note']],
      ['could-not', ['could-not']],
      ['wait', ['wait']]
    ]);
  });

  it('does not join a wait to a person post or a reply', () => {
    expect(
      shape([
        message('reply', 14, { reply_to: 'other', voice: Voice.Agent }),
        message('post', 13, { voice: Voice.Person }),
        waiting('wait', 12)
      ])
    ).toEqual([
      ['other', ['reply']],
      ['post', ['post']],
      ['wait', ['wait']]
    ]);
  });

  it('joins a reply, and a reply to the reply, to the note', () => {
    expect(
      shape([
        message('r2', 15, { author: roman, voice: Voice.Person, reply_to: 'r1' }),
        message('r1', 14, { author: ben, voice: Voice.Person, reply_to: 'note' }),
        message('note', 13),
        waiting('wait', 12)
      ])
    ).toEqual([['note', ['wait', 'note', 'r1', 'r2']]]);
  });

  it('leaves every other message a thread of one', () => {
    expect(shape([message('b', 13, { author: ben }), message('a', 12)])).toEqual([
      ['b', ['b']],
      ['a', ['a']]
    ]);
  });
});

describe('itemThreads', () => {
  const summary = (id: string, about?: string, created_at = '2026-11-13T10:00:00.000Z'): ItemSummary => ({
    id,
    kind: ItemKind.Notice,
    voice: Voice.Agent,
    author: ben,
    to: { circle: false, members: [] },
    title: id,
    status: ItemStatus.New,
    closed: false,
    created_at,
    ...(about === undefined ? {} : { about })
  });

  it('joins the items about one message and leaves the rest alone', () => {
    const threads = itemThreads([
      summary('reply', 'note', '2026-11-13T11:00:00.000Z'),
      summary('q'),
      summary('work', 'note', '2026-11-13T09:00:00.000Z')
    ]);
    expect(threads.map((t) => [t.key, t.shown.id, t.rows.map((i) => i.id)])).toEqual([
      ['note', 'reply', ['work', 'reply']],
      ['q', 'q', ['q']]
    ]);
  });
});
