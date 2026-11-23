// Member review (docs/design.md, Member review; DES-376): what the pages show of a member in review,
// to the admins and the member alone. The node works out In review and the newest outcome on read
// (member_summary's in_review_since and review); these turn them into the badge, the Review row,
// the admins a review asks and the command that removes a member.
import {
  ItemSubject,
  MemberStatus,
  ReviewOutcome,
  type Item,
  type MemberReview,
  type SignerSet
} from '#generated/ai-digestif-digestif-node.ts';
import { noteDate, type StatusLabel } from './format.ts';

/** The badge beside a member's Stage while they are in review. */
export const IN_REVIEW: StatusLabel = { label: 'In review', tone: 'warn' };

/** `digestif-update remove <identity>`: the admin key signs a revoke of that member. No page takes an admin key. */
export const removeCommand = (identity: string): string => 'digestif-update remove ' + identity;

/** The Review row: "Kept by Roman Cherkasov · Nov 16", or "Revoked by Sasha Petrov · Nov 14". */
export function reviewLine(review: MemberReview): string {
  return (review.outcome === ReviewOutcome.Kept ? 'Kept by ' : 'Revoked by ') + review.by.name + ' · ' + noteDate(review.at);
}

/** The admins a review asks: every member the signer set binds an unrevoked key to, once each. */
export function admins(signers: SignerSet | undefined): { identity: string; name: string }[] {
  const seen = new Map<string, string>();
  for (const s of signers?.signers ?? []) if (s.member !== undefined && !s.revoked) seen.set(s.member.identity, s.member.name);
  return [...seen.entries()].map(([identity, name]) => ({ identity, name }));
}

/** "Mike Bryzek (you), Roman Cherkasov": the admins asked, the reader marked when they are one. */
export function askedLine(signers: SignerSet | undefined, self: string | undefined): string {
  return admins(signers)
    .map((a) => a.name + (a.identity === self ? ' (you)' : ''))
    .join(', ');
}

/**
 * Which review page an item is: an admin's question about another member, the member's own notice
 * while in review or once kept, or the notice a removed member finds. Undefined for any other item.
 */
export type ReviewPage = 'admin' | 'member' | 'kept' | 'removed';

export function reviewPage(
  item: Pick<Item, 'subject' | 'about'>,
  member: { status: MemberStatus; in_review_since?: string; review?: MemberReview } | undefined,
  self: string | undefined
): ReviewPage | undefined {
  if (item.subject !== ItemSubject.Review || item.about === undefined || member === undefined) return undefined;
  if (item.about !== self) return 'admin';
  if (member.status === MemberStatus.Revoked && member.review?.outcome === ReviewOutcome.Revoked) return 'removed';
  if (member.in_review_since === undefined && member.review?.outcome === ReviewOutcome.Kept) return 'kept';
  return 'member';
}
