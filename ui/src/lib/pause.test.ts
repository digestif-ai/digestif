import { PauseReason } from '#generated/com-bryzek-digestif-node.ts';
import { describe, expect, it } from 'vitest';
import { dateAt, nextNoteWords, noteTimeWords, pausedSince, pauseWarningWords } from './pause.ts';

const local = (y: number, mo: number, d: number, h: number, mi: number): string => new Date(y, mo - 1, d, h, mi).toISOString();

describe('the words of a pause', () => {
  it('names a moment as the page does', () => {
    expect(dateAt(local(2026, 10, 24, 18, 15))).toBe('Oct 24 at 6:15 PM');
  });

  it('reads a Note time', () => {
    expect(noteTimeWords('07:00')).toBe('7:00 AM');
    expect(noteTimeWords('03:27')).toBe('3:27 AM');
    expect(noteTimeWords('00:05')).toBe('12:05 AM');
    expect(noteTimeWords('13:30')).toBe('1:30 PM');
  });

  it('warns with the note, how long it waited and when Digestif pauses', () => {
    const w = pauseWarningWords({
      note: { id: 'n1', written_at: local(2026, 11, 1, 8, 0) },
      waited_days: 27,
      pauses_at: local(2026, 12, 1, 8, 7)
    });
    expect(w.note + w.rest).toBe('Nov 1 Note has waited 27 days. Digestif pauses on Dec 1 at 8:07 AM unless it goes out.');
  });

  it('says why: Pause pressed, a note waiting 30 days, or nothing a phone can know', () => {
    const since = local(2026, 10, 24, 18, 15);
    expect(pausedSince(since, PauseReason.PressedPause)).toBe(
      'Digestif is paused. You pressed Pause on Oct 24 at 6:15 PM, and no notes are written while it stays paused.'
    );
    expect(pausedSince(since, PauseReason.NoteWaited)).toBe(
      'Digestif is paused. A note waited 30 days, so Digestif paused on Oct 24 at 6:15 PM, and no notes are written while it stays paused.'
    );
    expect(pausedSince(since)).toBe('Digestif is paused. It paused on Oct 24 at 6:15 PM, and no notes are written while it stays paused.');
  });

  it('says when the next note comes when none waits', () => {
    expect(nextNoteWords('07:00')).toBe(
      "Your next note comes at your usual time, 7:00 AM, and the circle's 24-hour window to hear from you restarts then. Any note that was waiting for you is still there."
    );
  });
});
