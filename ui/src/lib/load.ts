import { error } from '@sveltejs/kit';
import type { NodeError } from '#generated/com-bryzek-digestif-node.ts';
import { isApiError, type ApiResponse } from './api/client.ts';

/** A load's answer, or the error page with the node's own message and status. */
export function unwrap<T>(response: ApiResponse<T>): T {
  if (isApiError(response)) {
    const message = response.errors.map((e) => e.message).join(' ');
    error(response.status === 0 ? 503 : response.status, message);
  }
  return response.data;
}

/** A section's answer or its errors, for a page whose other sections render either way. */
export type Loaded<T> = { data: T } | { errors: NodeError[] };

export function loaded<T>(response: ApiResponse<T>): Loaded<T> {
  return isApiError(response) ? { errors: response.errors } : { data: response.data };
}
