// A local date and its window in time. The nightly note is keyed by local date (docs/design.md,
// The nightly note), so extraction takes the date and reads the day as [00:00, 24:00) local time.

export interface Day {
  /** YYYY-MM-DD. */
  date: string;
  /** Epoch milliseconds, inclusive. */
  start: number;
  /** Epoch milliseconds, exclusive. */
  end: number;
}

const DATE = /^(\d{4})-(\d{2})-(\d{2})$/;

/**
 * The window of a local date. With `utcOffsetMinutes` the day is read in that fixed offset (tests
 * pin it); without, in the machine's zone, with daylight-saving changes honoured by the Date
 * constructor.
 */
export function day(date: string, utcOffsetMinutes?: number): Day {
  const m = DATE.exec(date);
  if (!m) throw new Error(`not a date (YYYY-MM-DD): ${date}`);
  const y = Number(m[1]);
  const mo = Number(m[2]) - 1;
  const d = Number(m[3]);
  const check = new Date(Date.UTC(y, mo, d));
  if (check.getUTCFullYear() !== y || check.getUTCMonth() !== mo || check.getUTCDate() !== d) {
    throw new Error(`not a calendar date: ${date}`);
  }
  if (utcOffsetMinutes === undefined) {
    return { date, start: new Date(y, mo, d).getTime(), end: new Date(y, mo, d + 1).getTime() };
  }
  const shift = utcOffsetMinutes * 60_000;
  return { date, start: Date.UTC(y, mo, d) - shift, end: Date.UTC(y, mo, d + 1) - shift };
}

/** Today's local date, YYYY-MM-DD. */
export function today(now = new Date()): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())}`;
}

/** Parses an offset such as +02:00, -0500 or Z into minutes east of UTC. */
export function parseOffset(text: string): number {
  if (text === "Z" || text === "z") return 0;
  const m = /^([+-])(\d{2}):?(\d{2})$/.exec(text);
  if (!m) throw new Error(`not a UTC offset (+HH:MM): ${text}`);
  const minutes = Number(m[2]) * 60 + Number(m[3]);
  return m[1] === "-" ? -minutes : minutes;
}
