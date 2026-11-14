import {
  CircleApprovalKind,
  CircleApprovalState,
  type CircleApproval,
  type MemberRef,
  type SignerSet
} from '#generated/ai-digestif-digestif-node.ts';
import { describe, expect, it } from 'vitest';
import {
  approvalBadge,
  approvalName,
  approvalStatus,
  approvalTitle,
  canRemoveAdmin,
  EXPIRY_MARK,
  guestName,
  haltLine,
  INSTALL_MARK,
  inviteEmail,
  promotionSteps,
  regreet
} from './approvals.ts';

const ref = (first: string, last: string): MemberRef => ({ identity: 'ed25519:' + first, name: first + ' ' + last, agent_name: 'Agent' });
const mike = ref('Mike', 'Bryzek');
const roman = ref('Roman', 'Cherkasov');
const sasha = ref('Sasha', 'Petrov');
const andrey = ref('Andrey', 'Kartashov');

function approval(extra: Partial<CircleApproval>): CircleApproval {
  return {
    id: 'apv-1',
    kind: CircleApprovalKind.Invite,
    state: CircleApprovalState.Waiting,
    started_by: mike,
    created_at: '2026-11-13T19:10:00Z',
    expires_at: '2026-11-20T19:10:00Z',
    waiting_on: [],
    signed_count: 0,
    needed_count: 3,
    signers: [],
    ...extra
  };
}

const set = (revoked: string[], members: MemberRef[] = [mike, roman, sasha]): SignerSet => ({
  signers: members.map((m) => ({
    key: 'ed25519:rel' + m.identity,
    name: m.name.split(' ')[0] ?? '',
    member: m,
    revoked: revoked.includes(m.identity)
  })),
  halted: revoked.length > 0
});

describe('a waiting approval on Members', () => {
  it('names the guest, or the member and the role it moves them to', () => {
    expect(approvalName(approval({ guest: 'Priya Raman <priya@raman.dev>' }))).toBe('Priya Raman');
    expect(approvalName(approval({ kind: CircleApprovalKind.Promotion, member: andrey }))).toBe('Andrey Kartashov → admin');
    expect(approvalName(approval({ kind: CircleApprovalKind.Removal, member: roman }))).toBe('Roman Cherkasov → member');
    expect(approvalName(approval({ kind: CircleApprovalKind.Replacement, member: roman }))).toBe("Replace Roman's key");
  });

  it('says whom it waits on with the count, as one name, or a number when several', () => {
    expect(approvalStatus(approval({ waiting_on: [roman], signed_count: 2, needed_count: 3 }), mike.identity)).toEqual({
      label: 'Waiting on Roman · 2 of 3',
      tone: 'warn'
    });
    expect(approvalStatus(approval({ waiting_on: [roman, sasha, mike], signed_count: 1, needed_count: 4 }), mike.identity).label).toBe(
      'Waiting on 3 · 1 of 4'
    );
    expect(approvalStatus(approval({ waiting_on: [andrey], signed_count: 0, needed_count: 4 }), mike.identity).label).toBe(
      'Waiting on Andrey · 0 of 4'
    );
    expect(approvalStatus(approval({ state: CircleApprovalState.Declined }), mike.identity)).toEqual({
      label: 'Declined',
      tone: 'neutral'
    });
  });

  it('reads Waiting on you on the item of a reader who has not signed', () => {
    expect(approvalBadge(approval({ waiting_on: [roman], signed_count: 2 }), roman.identity).label).toBe('Waiting on you');
    expect(approvalBadge(approval({ waiting_on: [roman], signed_count: 2 }), mike.identity).label).toBe('Waiting on Roman · 2 of 3');
  });

  it('titles the promoted member’s own item Promote to Admin', () => {
    const p = approval({ kind: CircleApprovalKind.Promotion, member: andrey });
    expect(approvalTitle(p, andrey.identity)).toBe('Promote to Admin');
    expect(approvalTitle(p, mike.identity)).toBe('Promote Andrey Kartashov to Admin');
    expect(approvalTitle(approval({ guest: 'Priya Raman <priya@raman.dev>' }), mike.identity)).toBe('Invite Priya Raman');
  });
});

describe('the invite email', () => {
  it('starts from the email the node writes today, the install command and expiry left marked', () => {
    const { subject, body } = inviteEmail({ to: 'Priya Raman <priya@raman.dev>', sender: 'Mike Bryzek' });
    expect(subject).toBe('Join our circle on Digestif');
    const lines = body.split('\n');
    expect(lines[0]).toBe('Hi Priya,');
    expect(lines).toContain('  ' + INSTALL_MARK);
    expect(lines).toContain('This invite is yours alone and works once, until ' + EXPIRY_MARK + '.');
    expect(lines.at(-1)).toBe('Mike Bryzek');
  });

  it('greets by name as the To is typed, and only the greeting', () => {
    const body = inviteEmail({ to: '', sender: 'Mike Bryzek', message: 'Great to meet you.' }).body;
    expect(body.split('\n')[0]).toBe('Hi,');
    const greeted = regreet(body, 'Priya Raman <priya@raman.dev>', 'Mike Bryzek');
    expect(greeted.split('\n')[0]).toBe('Hi Priya,');
    expect(greeted.split('\n').slice(1)).toEqual(body.split('\n').slice(1));
  });

  it('reads the name from an address line', () => {
    expect(guestName('Priya Raman <priya@raman.dev>')).toBe('Priya Raman');
    expect(guestName('"Priya Raman" <priya@raman.dev>')).toBe('Priya Raman');
    expect(guestName('priya@raman.dev')).toBe('priya@raman.dev');
  });
});

describe('the halt line', () => {
  it('is absent while no revoked key is in the set', () => {
    expect(haltLine(set([]), [], mike.identity)).toBeUndefined();
  });

  it('names the revoked key and offers its removal', () => {
    expect(haltLine(set([roman.identity]), [], mike.identity)).toEqual({
      text: "Invites halted: Roman's key is revoked",
      lift: { text: 'Remove Roman as admin', href: '/members/' + encodeURIComponent(roman.identity) }
    });
  });

  it('shows the waiting removal instead, once one is filed', () => {
    const removal = approval({
      kind: CircleApprovalKind.Removal,
      member: roman,
      removed_key: 'ed25519:rel' + roman.identity,
      waiting_on: [sasha],
      signed_count: 2,
      needed_count: 3,
      item: 'itm-9'
    });
    expect(haltLine(set([roman.identity]), [removal], mike.identity)?.lift).toEqual({
      text: 'Roman Cherkasov → member: Waiting on Sasha · 2 of 3',
      href: '/inbox/itm-9'
    });
  });

  it('waits on a release when a removal would leave fewer than two keys', () => {
    expect(haltLine(set([roman.identity], [mike, roman]), [], mike.identity)?.lift).toEqual({
      text: 'Waiting on the release naming the new signers'
    });
    expect(canRemoveAdmin(set([], [mike, roman]))).toBe(false);
    expect(canRemoveAdmin(set([]))).toBe(true);
  });
});

it('gives the promoted member the four lines, the last of which signs', () => {
  const lines = promotionSteps('apv-Q3m9Ta').split('\n');
  expect(lines).toHaveLength(4);
  expect(lines[0]).toBe('digestif-update keygen ~/Downloads/digestif-release.key');
  expect(lines[1]).toContain('rm -f ~/Downloads/digestif-release.key');
  expect(lines[2]).toContain('~/.config/digestif/signer.json');
  expect(lines[3]).toBe('digestif-update approve apv-Q3m9Ta');
});
