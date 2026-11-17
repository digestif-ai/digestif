// What each release changed (DIG-128). The release carries its own entries in changelog.json, the
// Digestif product's entries of the changelog idempotent writes, and the node serves it with the rest
// of the UI it embeds, so a member reads it offline and without an idempotent login.

export type ChangelogCategory = 'feature' | 'improvement' | 'fix' | 'other';

export interface ChangelogEntry {
  summary: string;
  category: ChangelogCategory;
}

export interface ChangelogVersion {
  /** MAJOR.MINOR.PATCH, as a release tag names it without its v. */
  version: string;
  released_at?: string | undefined;
  entries: ChangelogEntry[];
}

export interface Changelog {
  versions: ChangelogVersion[];
}

/** Where the build puts it: ui/static/changelog.json. */
export const CHANGELOG_PATH = '/changelog.json';

const CATEGORY_LABEL: Record<ChangelogCategory, string> = {
  feature: 'New',
  improvement: 'Improved',
  fix: 'Fixed',
  other: 'Changed'
};
export const categoryLabel = (c: ChangelogCategory): string => CATEGORY_LABEL[c] ?? 'Changed';

/** [v] as numbers, or undefined when it is not MAJOR.MINOR.PATCH. */
function parts(v: string): [number, number, number] | undefined {
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(v.trim());
  return m === null ? undefined : [Number(m[1]), Number(m[2]), Number(m[3])];
}

/** Negative when [a] is older than [b]; an unreadable version sorts oldest. */
export function compareVersions(a: string, b: string): number {
  const x = parts(a);
  const y = parts(b);
  if (x === undefined || y === undefined) return (x === undefined ? 0 : 1) - (y === undefined ? 0 : 1);
  return x[0] - y[0] || x[1] - y[1] || x[2] - y[2];
}

/**
 * The versions the running node holds, newest first: its own and every one before it. A build that is
 * no release (0.0.0) or names no version shows every version the file holds.
 */
export function shownVersions(log: Changelog, running: string | undefined): ChangelogVersion[] {
  const newestFirst = [...log.versions].sort((a, b) => compareVersions(b.version, a.version));
  if (running === undefined || parts(running) === undefined || running === '0.0.0') return newestFirst;
  return newestFirst.filter((v) => compareVersions(v.version, running) <= 0);
}

/** The file read, or an error naming why not; an entry missing its summary is left out. */
export async function readChangelog(fetcher: typeof fetch): Promise<Changelog> {
  const response = await fetcher(CHANGELOG_PATH);
  if (!response.ok) throw new Error('The changelog did not load: HTTP ' + String(response.status) + '.');
  const json = (await response.json()) as { versions?: unknown };
  const versions = Array.isArray(json.versions) ? (json.versions as ChangelogVersion[]) : [];
  return {
    versions: versions
      .filter((v) => typeof v?.version === 'string')
      .map((v) => ({
        version: v.version,
        released_at: typeof v.released_at === 'string' ? v.released_at : undefined,
        entries: (Array.isArray(v.entries) ? v.entries : []).filter((e) => typeof e?.summary === 'string' && e.summary !== '')
      }))
  };
}
