import { error } from '@sveltejs/kit';
import { MemberStatus, type Member, type MemberSummary, type NodeError } from '#generated/ai-digestif-digestif-node.ts';
import { isApiError, type ApiResponse } from './api/client.ts';
import type { PageQuery } from './paging.ts';

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

/**
 * The member this node is (GET /members/self, DIG-225), or undefined before they have joined: a read
 * of one member, never a scan of the circle, so it holds however large the circle grows.
 */
export async function selfOf(client: { self(): Promise<ApiResponse<Member>> }): Promise<Member | undefined> {
  const response = await client.self();
  return response.status === 404 ? undefined : unwrap(response);
}

/** Rows a page of the circle holds: the node's largest page. */
const MEMBER_PAGE = 200;

/**
 * Every member of the circle, for a form that names some of them (DIG-225): page after page by the
 * cursor until a page comes back short, so no member past the first page is left out. A revoked
 * identity is a row of Members (DES-376) but no longer in the circle, so it is left out here.
 */
export async function everyMember(client: { members(page?: PageQuery): Promise<ApiResponse<MemberSummary[]>> }): Promise<MemberSummary[]> {
  const all: MemberSummary[] = [];
  for (;;) {
    const page = unwrap(await client.members({ limit: MEMBER_PAGE, cursor: all[all.length - 1]?.identity }));
    all.push(...page);
    if (page.length < MEMBER_PAGE) return all.filter((m) => m.status !== MemberStatus.Revoked);
  }
}
