import { StatusNote, Voice, type FeedItem, type ItemSummary } from '#generated/com-bryzek-digestif-node.ts';

// Threads (ISS-85464): rows about the same thing are one thread, the way a mail client threads a
// conversation. A list shows each thread once, as one row, and opening it shows every row in order. Nothing is stored: a thread is read off the rows a list already holds.

export interface Thread<T> {
  /** What the rows share; the thread's address. */
  key: string;
  /**
   * The row the list shows for the thread: its first in the list's own order. The Feed lists newest
   * first, so that is the latest message; the Inbox lists Draft and New first, so it is the newest
   * item still waiting on the member, and the latest once nothing waits.
   */
  shown: T;
  /** Every row, oldest first. */
  rows: T[];
}

type Timed = { created_at: string };

/**
 * [rows], in the list's own order, as threads, each where the list first shows one of its rows. Each
 * row's key comes from [keyOf]; rows with no shared key are a thread of one. A thread's rows are in
 * the order they were written.
 */
export function threadsOf<T extends Timed>(rows: T[], keyOf: (row: T) => string): Thread<T>[] {
  const byKey = new Map<string, T[]>();
  for (const row of rows) {
    const key = keyOf(row);
    byKey.set(key, [...(byKey.get(key) ?? []), row]);
  }
  return [...byKey].map(([key, members]) => {
    const ordered = [...members].sort((a, b) => a.created_at.localeCompare(b.created_at));
    return { key, shown: members[0]!, rows: ordered };
  });
}

/** An Inbox item's thread: the message it came from, so every item about one note is one thread; else the item alone. */
export const itemThreadKey = (item: Pick<ItemSummary, 'id' | 'about'>): string => item.about ?? item.id;

/** The Inbox's rows as threads. */
export const itemThreads = (items: ItemSummary[]): Thread<ItemSummary>[] => threadsOf(items, itemThreadKey);

/** A note an agent wrote for its member: what a waiting-for-approval status note is waiting on. */
const isAgentNote = (m: FeedItem): boolean =>
  m.status_note === undefined && m.reply_to === undefined && m.voice === Voice.Agent && m.kind === 'summary';

/**
 * Each Feed message's thread key, by hash. A reply joins the thread of the note it answers. A
 * "waiting for approval" status note joins the note its author's agent sends next, so the day's "No
 * note from Roman today" and the note that then goes out are one thread; several days of waiting are
 * the same thread. Until the note goes out, the waiting days are a thread of their own, keyed by the
 * first of them; any other status note from the author ends that wait.
 */
export function feedThreadKeys(feed: FeedItem[]): Map<string, string> {
  const keys = new Map<string, string>();
  const waiting = new Map<string, FeedItem[]>(); // by author, oldest first
  const settle = (identity: string, key: string): void => {
    for (const m of waiting.get(identity) ?? []) keys.set(m.hash, key);
    waiting.delete(identity);
  };
  const oldestFirst = [...feed].sort((a, b) => a.created_at.localeCompare(b.created_at));
  for (const m of oldestFirst) {
    const who = m.author.identity;
    if (m.status_note === StatusNote.WaitingForApproval) {
      waiting.set(who, [...(waiting.get(who) ?? []), m]);
      continue;
    }
    if (m.status_note !== undefined) {
      const first = waiting.get(who)?.[0];
      if (first !== undefined) settle(who, first.hash);
    } else if (isAgentNote(m)) settle(who, m.hash);
    keys.set(m.hash, m.hash);
  }
  for (const [who, rows] of waiting) settle(who, rows[0]!.hash);
  // A reply takes its note's thread; a reply to a message the feed does not hold, that message's hash.
  for (const m of oldestFirst) {
    if (m.reply_to !== undefined) keys.set(m.hash, keys.get(m.reply_to) ?? m.reply_to);
  }
  return keys;
}

/** The Feed's messages as threads. */
export function feedThreads(feed: FeedItem[]): Thread<FeedItem>[] {
  const keys = feedThreadKeys(feed);
  return threadsOf(feed, (m) => keys.get(m.hash) ?? m.hash);
}
