import { isApiError, type ApiResponse } from './api/client.ts';
import type { NodeError } from '#generated/com-bryzek-digestif-node.ts';

/**
 * One request in flight. `run` sets the flag before the request leaves and clears it only after
 * the follow-up (usually a refresh) finished, so the button never reads idle over stale state.
 * `key` lets a page answer one of several things without blocking the others.
 */
export class Submission {
  #pending = $state<string | undefined>(undefined);
  errors = $state<NodeError[]>([]);

  pending(key = ''): boolean {
    return this.#pending === key;
  }

  busy(): boolean {
    return this.#pending !== undefined;
  }

  async run<T>(request: () => Promise<ApiResponse<T>>, after: (data: T) => Promise<void> | void, key = ''): Promise<void> {
    if (this.#pending !== undefined) return;
    this.#pending = key;
    this.errors = [];
    try {
      const response = await request();
      if (isApiError(response)) this.errors = response.errors;
      else await after(response.data);
    } finally {
      this.#pending = undefined;
    }
  }

  fieldError(field: string): string | undefined {
    return this.errors.find((e) => e.field === field)?.message;
  }

  generalErrors(fields: string[] = []): NodeError[] {
    return this.errors.filter((e) => e.field === undefined || !fields.includes(e.field));
  }
}
