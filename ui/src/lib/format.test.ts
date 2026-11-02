import {
  ApprovalSetting,
  AskStatus,
  CheckState,
  MemberStage,
  MemberStatus,
  MessageStatus,
  NoteStatus,
  ProblemJob,
  ProblemKind,
  Stage,
  StatusNote,
  Voice,
  type Problem
} from '#generated/com-bryzek-digestif-node.ts';
import { describe, expect, it } from 'vitest';
import {
  approvalSetting,
  askStatus,
  checksLine,
  clockTime,
  logLine,
  memberStage,
  memberStatus,
  messageStatus,
  noteStatus,
  noteTime,
  problemLines,
  relativeTime,
  shortKey,
  speaker,
  statusNoteWords
} from './format.ts';

describe('relativeTime', () => {
  const now = new Date('2026-10-29T12:00:00.000Z');
  it('reads past times', () => {
    expect(relativeTime('2026-10-29T11:59:30.000Z', now)).toBe('just now');
    expect(relativeTime('2026-10-29T11:57:00.000Z', now)).toBe('3m ago');
    expect(relativeTime('2026-10-29T07:00:00.000Z', now)).toBe('5h ago');
    expect(relativeTime('2026-10-27T12:00:00.000Z', now)).toBe('2d ago');
    expect(relativeTime('2026-10-01T12:00:00.000Z', now)).toBe('2026-10-01');
  });
  it('reads future times', () => {
    expect(relativeTime('2026-10-29T16:00:00.000Z', now)).toBe('in 4h');
  });
});

describe('checksLine', () => {
  it('names each check and its state, never what it removed', () => {
    expect(checksLine({ pii: CheckState.Passed, rules: CheckState.Passed })).toBe('PII check Passed · Rules check Passed');
    expect(checksLine({ pii: CheckState.Running, rules: CheckState.CouldNotFinish })).toBe(
      'PII check running · Rules check could not finish'
    );
  });
});

describe('status tones', () => {
  it('uses color for status, and the words carry the meaning', () => {
    expect(noteStatus(NoteStatus.Waiting)).toEqual({ label: 'Waiting', tone: 'warn' });
    expect(noteStatus(NoteStatus.AutoApproved)).toEqual({ label: 'Auto approved', tone: 'good' });
    expect(messageStatus(MessageStatus.Posted).tone).toBe('good');
    expect(messageStatus(MessageStatus.Refused).tone).toBe('bad');
    expect(askStatus(AskStatus.Open).tone).toBe('info');
    expect(memberStatus(MemberStatus.Revoked).tone).toBe('bad');
  });
});

describe('stages and the status note', () => {
  it('reads a stage, and an invite not yet used, from one table of words', () => {
    expect(memberStage(Stage.Active)).toEqual({ label: 'Active', tone: 'good' });
    expect(memberStage(Stage.Paused)).toEqual({ label: 'Paused', tone: 'warn' });
    expect(memberStage(Stage.Onboarding).label).toBe('Onboarding');
    expect(memberStage(MemberStage.Invited).label).toBe('Invited');
  });

  it('renders the fixed words from the name, never from text', () => {
    expect(statusNoteWords(StatusNote.WaitingForApproval, 'Dana Ruiz')).toBe('Waiting for Dana to approve.');
    expect(statusNoteWords(StatusNote.CouldNotRun, 'Dana Ruiz')).toBe('Could not run today.');
    expect(statusNoteWords(StatusNote.NothingToShare, 'Dana Ruiz')).toBe('Nothing to share today.');
    expect(statusNoteWords(StatusNote.Paused, 'Dana Ruiz')).toBe('Paused.');
  });
});

describe('speaker', () => {
  const author = { name: 'Mike', agent_name: 'Athena' };
  it('names the person and the agent as two voices', () => {
    expect(speaker(Voice.Person, author)).toBe('Mike');
    expect(speaker(Voice.Agent, author)).toBe("Athena (Mike's agent)");
  });
});

describe('shortKey', () => {
  it('keeps the scheme and the first characters', () => {
    expect(shortKey('ed25519:abcdefghijklmnop')).toBe('ed25519:abcdefghij…');
  });
});

describe('problemLines', () => {
  // Local times, so the words do not depend on the zone the tests run in.
  const at = (h: number, m: number): string => new Date(2026, 10, 1, h, m).toISOString();
  const now = new Date(2026, 10, 1, 9, 0);
  const problem = (over: Partial<Problem>): Problem => ({
    id: 'p',
    job: ProblemJob.WriteVersion,
    kind: ProblemKind.SignedOut,
    first_seen_at: at(3, 27),
    last_seen_at: at(4, 27),
    count: 2,
    ...over
  });
  it('says each open problem once, since it was first seen', () => {
    expect(problemLines([problem({})], now)).toEqual(['Agent signed out since 3:27 AM']);
  });
  it('is one line for two jobs failing the same way, since the earliest', () => {
    const lines = problemLines([problem({}), problem({ id: 'q', job: ProblemJob.RulesCheck, first_seen_at: at(2, 5) })], now);
    expect(lines).toEqual(['Agent signed out since 2:05 AM']);
  });
  it('names a source by its label and a job that failed otherwise by the job, never a closed one', () => {
    const lines = problemLines(
      [
        problem({ job: ProblemJob.Source, kind: ProblemKind.SourceFailed, source: 'Athena', first_seen_at: at(1, 0) }),
        problem({ job: ProblemJob.SelfUpdate, kind: ProblemKind.Failed, first_seen_at: new Date(2026, 9, 30, 8, 15).toISOString() }),
        problem({ job: ProblemJob.Sync, kind: ProblemKind.RelayUnreachable, closed_at: at(5, 0) })
      ],
      now
    );
    expect(lines).toEqual(['Self-update failed since Oct 30, 8:15 AM', 'Athena could not be read since 1:00 AM']);
  });
  it('says when a check that could not finish runs again', () => {
    expect(clockTime(at(4, 27), now)).toBe('4:27 AM');
    expect(
      logLine({
        at: at(3, 27),
        event: 'could_not_finish',
        check: 'rules',
        problem: ProblemKind.SignedOut,
        retry_at: at(4, 27)
      } as Parameters<typeof logLine>[0])
    ).toMatch(/^Rules check could not finish: agent signed out; it runs again /);
  });
});

describe('noteTime', () => {
  it('reads HH:MM on a twelve-hour clock', () => {
    expect(noteTime('07:00')).toBe('7:00 AM');
    expect(noteTime('00:05')).toBe('12:05 AM');
    expect(noteTime('12:30')).toBe('12:30 PM');
    expect(noteTime('23:59')).toBe('11:59 PM');
  });
});

describe('approvalSetting', () => {
  it('names each choice as its edit page does', () => {
    expect(approvalSetting(ApprovalSetting.EveryNoteWaits)).toBe('Every note waits for me');
    expect(approvalSetting(ApprovalSetting.AutoApprove)).toBe('Auto approve every note');
  });
});
