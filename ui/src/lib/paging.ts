/**
 * The node's long lists (notes, asks, members, the deny list) read one page at a time by a limit
 * and a cursor, the id of the last row of the page before (ISS-41988). A screen asks for one row
 * more than it shows, so it knows whether More has anything to read.
 */

/** Rows a list screen shows before More. */
export const LIST_PAGE = 50;

/** One page, as a list route takes it. */
export interface PageQuery {
  limit: number;
  cursor?: string | undefined;
}

/** The page a screen reads: one more row than it shows, after [cursor] when there is one. */
export function pageQuery(cursor?: string, size: number = LIST_PAGE): PageQuery {
  return { limit: size + 1, cursor };
}

/** [query] as URL parameters, after any the route already carries. */
export function withPage(url: string, query?: PageQuery): string {
  if (query === undefined) return url;
  const params = new URLSearchParams();
  params.set('limit', String(query.limit));
  if (query.cursor !== undefined) params.set('cursor', query.cursor);
  return url + (url.includes('?') ? '&' : '?') + params.toString();
}

/** The rows a screen shows of what the node answered, and whether there are more. */
export interface Page<T> {
  rows: T[];
  more: boolean;
}

export function pageOf<T>(answered: T[], size: number = LIST_PAGE): Page<T> {
  return { rows: answered.slice(0, size), more: answered.length > size };
}

/** The cursor More reads after: the id of the last row shown. */
export function cursorAfter<T>(rows: T[], idOf: (row: T) => string): string | undefined {
  const last = rows[rows.length - 1];
  return last === undefined ? undefined : idOf(last);
}
