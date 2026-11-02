/** Every page address in one place, so list rows and breadcrumbs agree. */
const seg = (s: string): string => encodeURIComponent(s);

export const href = {
  feed: (): string => '/feed',
  message: (hash: string): string => '/feed/' + seg(hash),
  asks: (): string => '/asks',
  ask: (id: string): string => '/asks/' + seg(id),
  members: (): string => '/members',
  member: (identity: string): string => '/members/' + seg(identity),
  dinners: (): string => '/dinners',
  dinner: (hash: string): string => '/dinners/' + seg(hash),
  /** Settings is one page; each of its sections has an edit page under it. */
  settings: (): string => '/settings',
  sourcesEdit: (): string => '/settings/sources',
  briefEdit: (): string => '/settings/brief',
  rulesEdit: (): string => '/settings/rules',
  learningsEdit: (): string => '/settings/learnings',
  denyList: (): string => '/settings/deny',
  deny: (id: string): string => '/settings/deny/' + seg(id),
  approvalEdit: (): string => '/settings/approval',
  noteTimeEdit: (): string => '/settings/note-time',
  quietHours: (): string => '/settings/quiet-hours',
  phones: (): string => '/settings/phones',
  phoneNew: (): string => '/settings/phones/new',
  approvals: (): string => '/approvals',
  approval: (hash: string): string => '/approvals/' + seg(hash),
  /** The phone web app, which the mailing relay serves on its own origin. */
  phone: (): string => '/app',
  phoneAsk: (hash: string): string => '/app/asks/' + seg(hash),
  phonePair: (): string => '/app/pair'
};
