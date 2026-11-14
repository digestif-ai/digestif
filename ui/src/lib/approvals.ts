// The admins' approvals as the pages say them (DES-85466, design/digestif/admins.html): a Members
// row's name and status, the halt line, the invite email an admin starts from, and the commands an
// Inbox item hands the admin to copy. A signature is the command's, never a page's.
import {
  CircleApprovalKind,
  CircleApprovalState,
  MemberRole,
  type CircleApproval,
  type MemberRef,
  type SignerSet
} from '#generated/ai-digestif-digestif-node.ts';
import type { StatusLabel } from './format.ts';
import { href } from './href.ts';

const first = (name: string): string => name.trim().split(/\s+/)[0] ?? name;

/** The name part of an address line, `Priya Raman <priya@raman.dev>` → `Priya Raman`; a bare address is its own name. */
export function guestName(to: string): string {
  const line = to.trim();
  const lt = line.indexOf('<');
  const name = (lt < 0 ? line : line.slice(0, lt)).trim().replace(/^"|"$/g, '');
  return name === '' ? line.replace(/[<>]/g, '') : name;
}

export const isAdmin = (m: { role: MemberRole } | undefined): boolean => m?.role === MemberRole.Admin;

/** A Members row's name for a waiting approval: the guest, "Andrey Kartashov → admin", "Roman Cherkasov → member", "Replace Roman's key". */
export function approvalName(a: Pick<CircleApproval, 'kind' | 'guest' | 'member'>): string {
  const member = a.member?.name ?? '';
  switch (a.kind) {
    case CircleApprovalKind.Invite:
      return guestName(a.guest ?? '');
    case CircleApprovalKind.Promotion:
      return member + ' → admin';
    case CircleApprovalKind.Removal:
      return member + ' → member';
    case CircleApprovalKind.Replacement:
      return 'Replace ' + first(member) + "'s key";
  }
}

/** The Inbox item's title for an approval, as the reader reads it. */
export function approvalTitle(a: Pick<CircleApproval, 'kind' | 'guest' | 'member'>, self: string | undefined): string {
  switch (a.kind) {
    case CircleApprovalKind.Invite:
      return 'Invite ' + guestName(a.guest ?? '');
    case CircleApprovalKind.Promotion:
      return a.member?.identity === self ? 'Promote to Admin' : 'Promote ' + (a.member?.name ?? '') + ' to Admin';
    case CircleApprovalKind.Removal:
      return 'Remove ' + (a.member?.name ?? '') + ' as Admin';
    case CircleApprovalKind.Replacement:
      return approvalName(a);
  }
}

/** Whom it waits on: one name, "you", or a count once more than one has not signed. */
function waitingOn(waiting: MemberRef[], self: string | undefined): string {
  if (waiting.length === 1) return waiting[0]?.identity === self ? 'you' : first(waiting[0]?.name ?? '');
  return String(waiting.length);
}

const ENDED: Record<Exclude<CircleApprovalState, CircleApprovalState.Waiting>, StatusLabel> = {
  [CircleApprovalState.Signed]: { label: 'Signed', tone: 'good' },
  [CircleApprovalState.Declined]: { label: 'Declined', tone: 'neutral' },
  [CircleApprovalState.Expired]: { label: 'Expired', tone: 'neutral' },
  [CircleApprovalState.Halted]: { label: 'Halted', tone: 'bad' }
};

/** A Members row's status: "Waiting on Roman · 2 of 3", "Waiting on 3 · 1 of 4"; an ended one by how it ended. */
export function approvalStatus(
  a: Pick<CircleApproval, 'state' | 'waiting_on' | 'signed_count' | 'needed_count'>,
  self: string | undefined
): StatusLabel {
  if (a.state !== CircleApprovalState.Waiting) return ENDED[a.state];
  const who = a.waiting_on.length === 0 ? '' : 'Waiting on ' + waitingOn(a.waiting_on, self) + ' · ';
  return { label: who + String(a.signed_count) + ' of ' + String(a.needed_count), tone: 'warn' };
}

/** The item's own badge: Waiting on you while the reader has not signed, else the row's status. */
export function approvalBadge(
  a: Pick<CircleApproval, 'state' | 'waiting_on' | 'signed_count' | 'needed_count'>,
  self: string | undefined
): StatusLabel {
  if (a.state === CircleApprovalState.Waiting && a.waiting_on.some((m) => m.identity === self))
    return { label: 'Waiting on you', tone: 'warn' };
  return approvalStatus(a, self);
}

/** The one line an admin runs to sign: the release signer's tool, never a page. */
export const approveCommand = (id: string): string => 'digestif-update approve ' + id;

/**
 * The promoted member's four lines (docs/releases.md, Where the key comes from): make the key, move it
 * into the login Keychain and delete the file, write signer.json with the Keychain's key command, sign.
 */
export function promotionSteps(id: string): string {
  return [
    'digestif-update keygen ~/Downloads/digestif-release.key',
    'security add-generic-password -U -s digestif-release-key -a "$USER" -T "" -w "$(cat ~/Downloads/digestif-release.key)"; rm -f ~/Downloads/digestif-release.key',
    'mkdir -p ~/.config/digestif && printf \'%s\\n\' \'{ "key_command": "security find-generic-password -s digestif-release-key -w" }\' > ~/.config/digestif/signer.json',
    approveCommand(id)
  ].join('\n');
}

export const KEY_FROM_1PASSWORD = 'https://github.com/digestif-ai/digestif/blob/main/docs/releases.md#where-the-key-comes-from';

/** What a promotion's Role row says the member is asked to become. */
export const ADMIN_ROLE = 'Admin: signs every release, invite and promotion';

/**
 * The two marks the starting admin's node fills when it sends, once the dinner exists (DES-85466, An
 * invite); the node refuses a body missing either (Digestif_invite.Invite_email.command_mark and expiry_mark).
 */
export const INSTALL_MARK = '{{install_command}}';
export const EXPIRY_MARK = '{{expires_at}}';

const PARAGRAPH =
  'Digestif runs on your own machine: each day your coding agent writes a note on your work from the sources you choose and shares it with the circle, whose agents reply when one of them can help. Every note passes automatic checks that remove personal details and anything your rules forbid, and waits for your approval until you choose otherwise; all of the code is open source at github.com/digestif-ai/digestif.';

/**
 * The invite email an admin starts from, as node/invite/invite_email.ml renders it: the greeting, the
 * admin's own words, the fixed paragraph, the install command and the expiry as marked lines, the
 * closing and the admin's name. The subject names the circle (NodeStatus.circle_label), as the node's does;
 * a node not yet holding its root dinner names none.
 */
export function inviteEmail(view: { to: string; sender: string; circle?: string; message?: string }): {
  subject: string;
  body: string;
} {
  const guest = guestName(view.to);
  const greeting = guest === '' || guest.includes('@') ? 'Hi,' : 'Hi ' + first(guest) + ',';
  const circle = view.circle?.trim() ?? '';
  return {
    subject: circle === '' ? 'Join our circle on Digestif' : 'Join the ' + circle + ' circle on Digestif',
    body: [
      greeting,
      '',
      view.message ?? '',
      '',
      PARAGRAPH,
      '',
      'Paste this into a terminal on your Mac or Linux machine:',
      '',
      '  ' + INSTALL_MARK,
      '',
      'This invite is yours alone and works once, until ' + EXPIRY_MARK + '.',
      '',
      'And please let me know how else I can help.',
      '',
      view.sender
    ].join('\n')
  };
}

/** Swap the greeting of a body the admin has not otherwise changed, as they type the To. */
export function regreet(body: string, to: string, sender: string): string {
  const lines = body.split('\n');
  const greeting = inviteEmail({ to, sender }).body.split('\n')[0] ?? '';
  if (lines.length > 0 && /^Hi\b.*,$/.test(lines[0] ?? '')) lines[0] = greeting;
  return lines.join('\n');
}

/** What lifts a halt: the waiting removal's row, Remove <name> as admin, or the release a lost key needs. */
export type HaltLift = { text: string; href?: string };

/**
 * The status line Members shows an admin in place of Invite while a revoked key is in the set
 * (DES-85466, While a revoked key is in the set), or undefined when nothing halts admissions.
 */
export function haltLine(
  signers: SignerSet,
  approvals: CircleApproval[],
  self: string | undefined
): { text: string; lift: HaltLift } | undefined {
  if (!signers.halted) return undefined;
  const revoked = signers.signers.filter((s) => s.revoked);
  const names = revoked.map((s) => first(s.member?.name ?? s.name));
  const text =
    names.length <= 1
      ? 'Invites halted: ' + (names[0] ?? 'a') + "'s key is revoked"
      : 'Invites halted: ' + names.slice(0, -1).join(', ') + ' and ' + (names.at(-1) ?? '') + "'s keys are revoked";
  const clearing = approvals.find(
    (a) =>
      a.state === CircleApprovalState.Waiting &&
      (a.kind === CircleApprovalKind.Removal || a.kind === CircleApprovalKind.Replacement) &&
      revoked.some((s) => s.key === a.removed_key)
  );
  if (clearing !== undefined)
    return {
      text,
      lift: {
        text: approvalName(clearing) + ': ' + approvalStatus(clearing, self).label,
        ...(clearing.item === undefined ? {} : { href: href.item(clearing.item) })
      }
    };
  const removable = revoked.find((s) => s.member !== undefined);
  if (removable?.member !== undefined && signers.signers.length >= 3)
    return { text, lift: { text: 'Remove ' + first(removable.member.name) + ' as admin', href: href.member(removable.member.identity) } };
  return { text, lift: { text: 'Waiting on the release naming the new signers' } };
}

/** Remove as Admin is offered only while the set holds three or more keys: a set keeps at least two. */
export const canRemoveAdmin = (signers: SignerSet): boolean => signers.signers.length >= 3;
