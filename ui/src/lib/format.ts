import type {
  AskKind,
  CheckState,
  LogEntry,
  NoteStatus,
  AskStatus,
  GuestStatus,
  MemberStatus,
  MessageStatus,
  SilenceReason,
  SourceKind,
  Voice
} from '#generated/com-bryzek-digestif-node.ts';

/** The only colors in the UI. Every status maps to one tone; kinds stay plain text. */
export type Tone = 'neutral' | 'good' | 'warn' | 'bad' | 'info';

export interface StatusLabel {
  label: string;
  tone: Tone;
}

const MESSAGE: Record<MessageStatus, StatusLabel> = {
  posted: { label: 'Posted', tone: 'good' },
  refused: { label: 'Refused', tone: 'bad' },
  failed: { label: 'Not sent', tone: 'bad' },
  retracted: { label: 'Retracted', tone: 'neutral' }
};

const ASK: Record<AskStatus, StatusLabel> = {
  open: { label: 'Open', tone: 'info' },
  answered: { label: 'Answered', tone: 'good' },
  lapsed: { label: 'Lapsed', tone: 'neutral' },
  withdrawn: { label: 'Withdrawn', tone: 'neutral' }
};

const MEMBER: Record<MemberStatus, StatusLabel> = {
  active: { label: 'Active', tone: 'good' },
  silent: { label: 'Silent', tone: 'warn' },
  revoked: { label: 'Revoked', tone: 'bad' }
};

const GUEST: Record<GuestStatus, StatusLabel> = {
  invited: { label: 'Invited', tone: 'info' },
  joined: { label: 'Joined', tone: 'good' },
  expired: { label: 'Expired', tone: 'neutral' },
  revoked: { label: 'Revoked', tone: 'bad' }
};

const NOTE: Record<NoteStatus, StatusLabel> = {
  waiting: { label: 'Waiting', tone: 'warn' },
  approved: { label: 'Approved', tone: 'good' },
  auto_approved: { label: 'Auto approved', tone: 'good' }
};

export const messageStatus = (s: MessageStatus): StatusLabel => MESSAGE[s];
export const noteStatus = (s: NoteStatus): StatusLabel => NOTE[s];

const CHECK_STATE: Record<CheckState, string> = { running: 'running', passed: 'Passed', could_not_finish: 'could not finish' };
/** "PII check Passed · Rules check Passed": plain text, the Log says what was removed. */
export function checksLine(checks: { pii: CheckState; rules: CheckState }): string {
  return 'PII check ' + CHECK_STATE[checks.pii] + ' · Rules check ' + CHECK_STATE[checks.rules];
}

const CAUSE: Record<string, string> = {
  always_on: 'Always on',
  rules: 'Rules',
  learnings: 'Learnings',
  deny_list: 'Deny list',
  person: 'a person outside the circle'
};

/** One Log entry in words: by part and by what it broke, never by text. */
export function logLine(e: LogEntry): string {
  const check = e.check === 'pii' ? 'PII check' : 'Rules check';
  switch (e.event) {
    case 'read':
      return 'Read ' + (e.sources ?? []).map((s) => String(s.items) + ' from ' + s.label).join(', ');
    case 'written':
      return 'Written by your agent';
    case 'edited':
      return 'You edited it';
    case 'checked': {
      const removals = e.removals ?? [];
      if (removals.length === 0) return check + ': nothing removed';
      return (
        check +
        ' removed ' +
        removals
          .map(
            (r) =>
              String(r.count) +
              ' (' +
              (r.cause === 'detector' ? (r.detector ?? 'a detector') : (CAUSE[r.cause] ?? r.cause)) +
              ', ' +
              r.part +
              ')'
          )
          .join('; ')
      );
    }
    case 'could_not_finish':
      return check + ' could not finish' + (e.problem === 'signed_out' ? ': agent signed out' : '');
    case 'approved':
      return 'You approved it';
    case 'auto_approved':
      return 'Auto approved';
    case 'shared':
      return 'Shared with the circle';
    case 'signing_refused':
      return 'Not sent: the check at signing refused it';
    case 'learnings_updated':
      return 'Learnings updated from your edit';
    default:
      return 'A problem';
  }
}
export const askStatus = (s: AskStatus): StatusLabel => ASK[s];
export const memberStatus = (s: MemberStatus): StatusLabel => MEMBER[s];
export const guestStatus = (s: GuestStatus): StatusLabel => GUEST[s];

const ASK_KIND: Record<AskKind, string> = {
  intro: 'Intro',
  meeting: 'Meeting',
  share: 'Share past the rules',
  behavior: 'Install a behavior',
  join: 'Unexpected join'
};
export const askKind = (k: AskKind): string => ASK_KIND[k];

const SILENCE: Record<SilenceReason, string> = {
  asleep: 'Machine asleep',
  no_sources: 'No sources chosen',
  harness_signed_out: 'Agent harness not signed in',
  relay_rejecting: 'Relays rejecting',
  deny_refusing: 'Deny layer refusing'
};
export const silenceReason = (r: SilenceReason): string => SILENCE[r];

const SOURCE_KIND: Record<SourceKind, string> = { claude_code: 'Claude Code sessions', git: 'Git repositories', command: 'Command' };
export const sourceKind = (k: SourceKind): string => SOURCE_KIND[k];

/** Mike and Athena are two voices: the person by name, the agent by its own name. */
export function speaker(voice: Voice, author: { name: string; agent_name: string }): string {
  return voice === 'person' ? author.name : author.agent_name + ' (' + author.name + "'s agent)";
}

/** "3m ago", "5h ago", "2d ago", then the date. Future times read "in 4h". */
/** A note's name is its day: "Oct 31". */
export function noteDate(iso: string): string {
  return new Date(iso).toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
}

export function relativeTime(iso: string, now: Date = new Date()): string {
  const then = new Date(iso);
  const seconds = Math.round((now.getTime() - then.getTime()) / 1000);
  const future = seconds < 0;
  const abs = Math.abs(seconds);
  const say = (n: number, unit: string): string => (future ? 'in ' + String(n) + unit : String(n) + unit + ' ago');
  if (abs < 60) return future ? 'in a moment' : 'just now';
  if (abs < 3600) return say(Math.floor(abs / 60), 'm');
  if (abs < 86400) return say(Math.floor(abs / 3600), 'h');
  if (abs < 86400 * 7) return say(Math.floor(abs / 86400), 'd');
  return then.toISOString().slice(0, 10);
}

/** A key or hash is long; show its scheme and the first characters. */
export function shortKey(key: string): string {
  const [scheme, value] = key.includes(':') ? (key.split(':', 2) as [string, string]) : ['', key];
  return (scheme === '' ? '' : scheme + ':') + value.slice(0, 10) + '…';
}
