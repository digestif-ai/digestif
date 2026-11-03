import type { NodeError } from '#generated/com-bryzek-digestif-node.ts';
import { isApiError, type ApiResponse } from './api/client.ts';
import { LIST_PAGE, cursorAfter, pageOf, pageQuery, type Page, type PageQuery } from './paging.ts';

/**
 * A list screen's rows, its first page from the load and each More after it (ISS-41988). [read]
 * asks the node for one page; the rows a More reads are appended to what the screen shows.
 */
export class More<T> {
  rows = $state<T[]>([]);
  more = $state(false);
  loading = $state(false);
  errors = $state<NodeError[]>([]);

  constructor(
    first: Page<T>,
    private readonly idOf: (row: T) => string,
    private readonly read: (query: PageQuery) => Promise<ApiResponse<T[]>>,
    private readonly size: number = LIST_PAGE
  ) {
    this.rows = first.rows;
    this.more = first.more;
  }

  async load(): Promise<void> {
    if (this.loading) return;
    this.loading = true;
    this.errors = [];
    try {
      const response = await this.read(pageQuery(cursorAfter(this.rows, this.idOf), this.size));
      if (isApiError(response)) {
        this.errors = response.errors;
        return;
      }
      const page = pageOf(response.data, this.size);
      this.rows = [...this.rows, ...page.rows];
      this.more = page.more;
    } finally {
      this.loading = false;
    }
  }
}
