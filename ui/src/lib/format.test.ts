import { ApprovalSetting, AskStatus, MemberStatus, MessageStatus, Voice } from '#generated/com-bryzek-digestif-node.ts';
import { describe, expect, it } from 'vitest';
import { approvalSetting, askStatus, memberStatus, messageStatus, noteTime, relativeTime, shortKey, speaker } from './format.ts';

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

describe('status tones', () => {
  it('uses color for status, and the words carry the meaning', () => {
    expect(messageStatus(MessageStatus.AwaitingApproval)).toEqual({ label: 'Awaiting approval', tone: 'warn' });
    expect(messageStatus(MessageStatus.Refused).tone).toBe('bad');
    expect(askStatus(AskStatus.Open).tone).toBe('info');
    expect(memberStatus(MemberStatus.Silent)).toEqual({ label: 'Silent', tone: 'warn' });
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
