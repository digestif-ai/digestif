import { AskStatus, CheckState, MemberStatus, MessageStatus, NoteStatus, Voice } from '#generated/com-bryzek-digestif-node.ts';
import { describe, expect, it } from 'vitest';
import { askStatus, checksLine, memberStatus, messageStatus, noteStatus, relativeTime, shortKey, speaker } from './format.ts';

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
