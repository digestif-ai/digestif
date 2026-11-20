import type { FeedItem } from '#generated/ai-digestif-digestif-node.ts';
import { isApiError, type ApiResponse, type Client } from './api/client.ts';
import type { PageQuery } from './paging.ts';

/** The most messages the node answers in one page. */
export const FEED_MAX = 200;

/**
 * The Feed reads one page at a time, newest first (DIG-213): the node pages it by `before` and
 * answers only messages strictly older than it. The first page and every More read through here.
 */
export function readFeed(client: Pick<Client, 'feed'>, query: PageQuery): Promise<ApiResponse<FeedItem[]>> {
  return client.feed({ limit: query.limit, before: query.cursor });
}

/** The cursor a Feed message stands for: its created_at, which More reads from. */
export const feedCursor = (m: Pick<FeedItem, 'created_at'>): string => m.created_at;

/**
 * The page after [shown], the messages the Feed already holds. Two messages can share a
 * millisecond, and a strict `before` at the last one shown would skip any of its twins the page
 * before left out, so More reads from that millisecond, its own included, and drops the ones shown.
 */
export async function readOlder(client: Pick<Client, 'feed'>, shown: FeedItem[], query: PageQuery): Promise<ApiResponse<FeedItem[]>> {
  const at = query.cursor;
  const before = at === undefined ? undefined : feedFrom(at);
  if (at === undefined || before === undefined) return readFeed(client, query);
  const tied = new Set(shown.filter((m) => m.created_at === at).map((m) => m.hash));
  const response = await client.feed({ limit: Math.min(query.limit + tied.size, FEED_MAX), before });
  if (isApiError(response)) return response;
  return { ...response, data: response.data.filter((m) => !tied.has(m.hash)) };
}

/**
 * The `before` that reads a page starting at [at], the created_at of a message, with that message
 * included: the node's cursor is exclusive, so one millisecond later.
 */
export function feedFrom(at: string): string | undefined {
  const t = Date.parse(at);
  return Number.isNaN(t) ? undefined : new Date(t + 1).toISOString();
}
