// The words of a pause (docs/design.md, Pause): the banner three days before one, and the Paused
// page's paragraph, which the laptop and a paired phone both show. The paragraph is the one place
// the UI explains itself under a title: the member is locked out of everything else.
import { PauseReason, type PauseWarning } from '#generated/com-bryzek-digestif-node.ts';
import { noteDate } from './format.ts';

/** "Oct 24 at 6:15 PM". */
export function dateAt(iso: string): string {
  const time = new Date(iso).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
  return noteDate(iso) + ' at ' + time;
}

/** A Note time, HH:MM local, as the member reads it: "7:00 AM". */
export function noteTimeWords(hhmm: string): string {
  const [h, m] = hhmm.split(':').map(Number);
  const hour = h ?? 0;
  const suffix = hour < 12 ? 'AM' : 'PM';
  return String(hour % 12 === 0 ? 12 : hour % 12) + ':' + String(m ?? 0).padStart(2, '0') + ' ' + suffix;
}

/** The banner, before its link: "Nov 1 Note has waited 27 days. Digestif pauses on Dec 1 at 8:07 AM unless it goes out." */
export function pauseWarningWords(w: PauseWarning): { note: string; rest: string } {
  const days = w.waited_days === 1 ? '1 day' : String(w.waited_days) + ' days';
  return {
    note: noteDate(w.note.written_at) + ' Note',
    rest: ' has waited ' + days + '. Digestif pauses on ' + dateAt(w.pauses_at) + ' unless it goes out.'
  };
}

/**
 * The opening of the Paused page: that Digestif is paused, since when, and why. A phone learns the
 * stage from the member's Paused note and nothing of why, so it passes no reason.
 */
export function pausedSince(since: string, reason?: PauseReason): string {
  const why =
    reason === undefined
      ? 'It paused on '
      : reason === PauseReason.NoteWaited
        ? 'A note waited 30 days, so Digestif paused on '
        : 'You pressed Pause on ';
  return 'Digestif is paused. ' + why + dateAt(since) + ', and no notes are written while it stays paused.';
}

export const UNPAUSE_WORDS = 'Unpause makes you Active right away, but it does not write a note on the spot.';

/** The next-note sentence when no note waits. A waiting note is named with a link instead. */
export function nextNoteWords(noteTime: string): string {
  return (
    'Your next note comes at your usual time, ' +
    noteTimeWords(noteTime) +
    ", and the circle's 24-hour window to hear from you restarts then. Any note that was waiting for you is still there."
  );
}

/** The phone's one more line: it learns the stage from the member's next note. */
export const PHONE_UNPAUSE_WORDS = 'Unpause can take up to a day to show here.';
