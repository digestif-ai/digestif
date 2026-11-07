import { describe, expect, it } from 'vitest';
import { LIST_PAGE, cursorAfter, pageOf, pageQuery, withPage } from './paging.ts';

describe('paging', () => {
  it('asks for one row more than a page, after the cursor (ISS-41988)', () => {
    expect(pageQuery()).toEqual({ limit: LIST_PAGE + 1, cursor: undefined });
    expect(pageQuery('n-9', 10)).toEqual({ limit: 11, cursor: 'n-9' });
  });

  it('puts the page on the URL, after any parameter the route carries', () => {
    expect(withPage('/api/v0/notes')).toBe('/api/v0/notes');
    expect(withPage('/api/v0/notes', { limit: 51 })).toBe('/api/v0/notes?limit=51');
    expect(withPage('/api/v0/items?status=new', { limit: 51, cursor: 'a b' })).toBe('/api/v0/items?status=new&limit=51&cursor=a+b');
  });

  it('shows a page and knows whether there is more', () => {
    const rows = Array.from({ length: 4 }, (_, i) => ({ id: 'r' + String(i) }));
    expect(pageOf(rows, 3)).toEqual({ rows: rows.slice(0, 3), more: true });
    expect(pageOf(rows, 4)).toEqual({ rows, more: false });
    expect(cursorAfter(pageOf(rows, 3).rows, (r) => r.id)).toBe('r2');
    expect(cursorAfter([], (r: { id: string }) => r.id)).toBeUndefined();
  });
});
