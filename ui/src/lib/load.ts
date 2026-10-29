import { error } from '@sveltejs/kit';
import { isApiError, type ApiResponse } from './api/client.ts';

/** A load's answer, or the error page with the node's own message and status. */
export function unwrap<T>(response: ApiResponse<T>): T {
  if (isApiError(response)) {
    const message = response.errors.map((e) => e.message).join(' ');
    error(response.status === 0 ? 503 : response.status, message);
  }
  return response.data;
}
