import type {
  AskKind,
  CheckState,
  LogEntry,
  NoteStatus,
  AskStatus,
  MemberStatus,
  MessageStatus,
  Problem,
  ProblemJob,
  ProblemKind,
  SourceKind,
  StatusNote,
  Voice
} from '#generated/com-bryzek-digestif-node.ts';
import { ApprovalSetting } from '#generated/com-bryzek-digestif-node.ts';

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
  active: { label: 'In the circle', tone: 'good' },
  revoked: { label: 'Revoked', tone: 'bad' }
};

/** A row of Members: a member's stage (Stage), or an invite not yet used (MemberStage). */
const STAGE: Record<string, StatusLabel> = {
  active: { label: 'Active', tone: 'good' },
  paused: { label: 'Paused', tone: 'warn' },
  onboarding: { label: 'Onboarding', tone: 'neutral' },
  invited: { label: 'Invited', tone: 'neutral' }
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
      return (
        check +
        ' could not finish' +
        (e.problem === undefined ? '' : ': ' + PROBLEM_KIND[e.problem]) +
        (e.retry_at === undefined ? '' : '; it runs again ' + clockTime(e.retry_at))
      );
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
    case 'problem':
      return e.problem === undefined ? 'A problem' : 'A problem: ' + PROBLEM_KIND[e.problem];
    default:
      return 'A problem';
  }
}

const PROBLEM_KIND: Record<ProblemKind, string> = {
  signed_out: 'agent signed out',
  model_unavailable: 'model unavailable',
  out_of_budget: 'agent out of budget',
  source_failed: 'a source could not be read',
  relay_unreachable: 'relay unreachable',
  signing_refused: 'the check at signing refused it',
  failed: 'failed'
};

const PROBLEM_JOB: Record<ProblemJob, string> = {
  sync: 'Sync',
  read_circle: 'Reading the circle',
  write_version: 'Writing the note',
  pii_check: 'PII check',
  rules_check: 'Rules check',
  send: 'Sending',
  source: 'A source',
  learnings: 'Updating Learnings',
  self_update: 'Self-update'
};

const PROBLEM_SUBJECT: Record<ProblemKind, string> = {
  signed_out: 'Agent signed out',
  model_unavailable: 'Model unavailable',
  out_of_budget: 'Agent out of budget',
  source_failed: 'A source could not be read',
  relay_unreachable: 'Relay unreachable',
  signing_refused: 'Signing refused a note',
  failed: 'Failed'
};

/** What a problem is, as the header of Notes says it: the kind, or the job when it failed otherwise. */
function problemSubject(p: Problem): string {
  if (p.kind === 'source_failed' && p.source !== undefined) return p.source + ' could not be read';
  if (p.kind === 'failed') return PROBLEM_JOB[p.job] + ' failed';
  return PROBLEM_SUBJECT[p.kind];
}

/** A time of day, with the date when it is not today: 3:27 AM, or Oct 30, 3:27 AM. */
export function clockTime(iso: string, now: Date = new Date()): string {
  const then = new Date(iso);
  const time = then.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
  return then.toDateString() === now.toDateString() ? time : noteDate(iso) + ', ' + time;
}

/**
 * The header of Notes: one data line per open problem, "Agent signed out since 3:27 AM". Two jobs
 * failing the same way (the writer and a check both signed out) are one line, since the earliest.
 */
export function problemLines(problems: Problem[], now: Date = new Date()): string[] {
  const since = new Map<string, string>();
  for (const p of problems) {
    if (p.closed_at !== undefined) continue;
    const subject = problemSubject(p);
    const at = since.get(subject);
    if (at === undefined || p.first_seen_at < at) since.set(subject, p.first_seen_at);
  }
  return [...since.entries()].sort((a, b) => a[1].localeCompare(b[1])).map(([subject, at]) => subject + ' since ' + clockTime(at, now));
}
export const askStatus = (s: AskStatus): StatusLabel => ASK[s];
export const memberStatus = (s: MemberStatus): StatusLabel => MEMBER[s];
export const memberStage = (s: string): StatusLabel => STAGE[s] ?? { label: s, tone: 'neutral' };

const STATUS_NOTE: Record<StatusNote, (firstName: string) => string> = {
  paused: () => 'Paused.',
  waiting_for_approval: (firstName) => 'Waiting for ' + firstName + ' to approve.',
  could_not_run: () => 'Could not run today.',
  nothing_to_share: () => 'Nothing to share today.'
};

/** A status note's fixed words, rendered from its name and the member's, never from text it carries
 * (docs/protocol.md, Content bodies). */
export const statusNoteWords = (s: StatusNote, memberName: string): string => STATUS_NOTE[s](memberName.split(' ')[0] ?? memberName);

const ASK_KIND: Record<AskKind, string> = {
  intro: 'Intro',
  meeting: 'Meeting',
  share: 'Share past the rules',
  behavior: 'Install a behavior',
  join: 'Unexpected join'
};
export const askKind = (k: AskKind): string => ASK_KIND[k];

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

/** Approval's two choices, in the words its edit page offers them. */
const APPROVAL: Record<ApprovalSetting, string> = {
  [ApprovalSetting.EveryNoteWaits]: 'Every note waits for me',
  [ApprovalSetting.AutoApprove]: 'Auto approve every note'
};
export const approvalSetting = (s: ApprovalSetting): string => APPROVAL[s];

/** Note time as a person reads it: "07:00" is 7:00 AM, "13:05" is 1:05 PM. */
export function noteTime(hhmm: string): string {
  const [h = 0, m = 0] = hhmm.split(':').map((x) => Number.parseInt(x, 10));
  const hour = h % 12 === 0 ? 12 : h % 12;
  return String(hour) + ':' + String(m).padStart(2, '0') + (h < 12 ? ' AM' : ' PM');
}
