import type { FeedItem } from '#generated/ai-digestif-digestif-node.ts';
import { describe, expect, it } from 'vitest';
import type { ApiResponse } from './api/client.ts';
import { feedCursor, feedFrom, readFeed, readOlder } from './feed.ts';
import { href } from './href.ts';
import { pageQuery } from './paging.ts';

/** A node that records the page it was asked for and answers nothing. */
function node() {
  const asked: ({ limit: number; before?: string | undefined } | undefined)[] = [];
  return {
    asked,
    feed: (page?: { limit: number; before?: string | undefined }): Promise<ApiResponse<FeedItem[]>> => {
      asked.push(page);
      return Promise.resolve({ data: [] } as unknown as ApiResponse<FeedItem[]>);
    }
  };
}

describe('feed paging (DIG-213)', () => {
  it('reads the first page with one row more than it shows, and More before the last message shown', async () => {
    const n = node();
    await readFeed(n, pageQuery());
    await readFeed(n, pageQuery(feedCursor({ created_at: '2026-11-12T12:00:00.000Z' })));
    expect(n.asked).toEqual([
      { limit: 51, before: undefined },
      { limit: 51, before: '2026-11-12T12:00:00.000Z' }
    ]);
  });

  it('reads a thread from its latest message, that message included', () => {
    expect(feedFrom('2026-11-12T12:00:00.000Z')).toBe('2026-11-12T12:00:00.001Z');
    expect(feedFrom('not a time')).toBeUndefined();
    expect(href.feedThread('sha256:ab', '2026-11-12T12:00:00.000Z')).toBe('/feed/threads/sha256%3Aab?at=2026-11-12T12%3A00%3A00.000Z');
    expect(href.feedThread('sha256:ab')).toBe('/feed/threads/sha256%3Aab');
  });
});

describe('More across a shared millisecond (DIG-213)', () => {
  const at = '2026-11-12T12:00:00.000Z';
  const row = (hash: string, created_at: string): FeedItem => ({ hash, created_at }) as FeedItem;

  it('reads from the last millisecond shown, its own included, and drops the messages already shown', async () => {
    const asked: ({ limit: number; before?: string | undefined } | undefined)[] = [];
    const answered = [row('b', at), row('c', at), row('d', '2026-11-12T11:00:00.000Z')];
    const client = {
      feed: (page?: { limit: number; before?: string | undefined }): Promise<ApiResponse<FeedItem[]>> => {
        asked.push(page);
        return Promise.resolve({ data: answered, status: 200 });
      }
    };
    const shown = [row('a', '2026-11-12T13:00:00.000Z'), row('b', at)];
    const page = await readOlder(client, shown, pageQuery(at));
    expect(asked).toEqual([{ limit: 52, before: '2026-11-12T12:00:00.001Z' }]);
    expect('data' in page && page.data.map((m) => m.hash)).toEqual(['c', 'd']);
  });

  it('reads the first page as it is', async () => {
    const n = node();
    await readOlder(n, [], pageQuery());
    expect(n.asked).toEqual([{ limit: 51, before: undefined }]);
  });
});
