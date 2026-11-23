import { ItemSubject, MemberStatus, ReviewOutcome, type MemberRef, type SignerSet } from '#generated/ai-digestif-digestif-node.ts';
import { describe, expect, it } from 'vitest';
import { askedLine, removeCommand, reviewLine, reviewPage } from './review.ts';

const ref = (first: string, last: string): MemberRef => ({ identity: 'ed25519:' + first, name: first + ' ' + last, agent_name: 'Agent' });
const mike = ref('Mike', 'Bryzek');
const roman = ref('Roman', 'Cherkasov');
const wei = ref('Wei', 'Zhang');

describe('member review', () => {
  it('names the newest outcome with its day', () => {
    expect(reviewLine({ outcome: ReviewOutcome.Kept, by: roman, at: '2026-11-16T15:00:00Z' })).toBe('Kept by Roman Cherkasov · Nov 16');
    expect(reviewLine({ outcome: ReviewOutcome.Revoked, by: roman, at: '2026-11-14T15:00:00Z' })).toBe(
      'Revoked by Roman Cherkasov · Nov 14'
    );
  });

  it('shows the command that removes a member', () => {
    expect(removeCommand(wei.identity)).toBe('digestif-update remove ed25519:Wei');
  });

  it('lists the admins asked, the reader marked', () => {
    const set: SignerSet = {
      halted: false,
      signers: [
        { key: 'k1', name: 'Mike', member: mike, revoked: false },
        { key: 'k2', name: 'Roman', member: roman, revoked: false },
        { key: 'k3', name: 'Old', revoked: true }
      ]
    };
    expect(askedLine(set, mike.identity)).toBe('Mike Bryzek (you), Roman Cherkasov');
  });

  it("tells an admin's item from the member's own notice, kept or removed", () => {
    const item = { subject: ItemSubject.Review, about: wei.identity };
    const open = { status: MemberStatus.Active, in_review_since: '2026-11-19T00:00:00Z' };
    expect(reviewPage(item, open, mike.identity)).toBe('admin');
    expect(reviewPage(item, open, wei.identity)).toBe('member');
    const kept = { status: MemberStatus.Active, review: { outcome: ReviewOutcome.Kept, by: roman, at: '2026-11-20T00:00:00Z' } };
    expect(reviewPage(item, kept, wei.identity)).toBe('kept');
    const removed = { status: MemberStatus.Revoked, review: { outcome: ReviewOutcome.Revoked, by: roman, at: '2026-11-20T00:00:00Z' } };
    expect(reviewPage(item, removed, wei.identity)).toBe('removed');
    expect(reviewPage({ subject: ItemSubject.Repositories, about: wei.identity }, open, mike.identity)).toBeUndefined();
  });
});
