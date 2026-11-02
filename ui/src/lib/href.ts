/** Every page address in one place, so list rows and breadcrumbs agree. */
const seg = (s: string): string => encodeURIComponent(s);

export const href = {
  feed: (): string => '/feed',
  message: (hash: string): string => '/feed/' + seg(hash),
  asks: (): string => '/asks',
  ask: (id: string): string => '/asks/' + seg(id),
  members: (): string => '/members',
  member: (identity: string): string => '/members/' + seg(identity),
  phoneNew: (): string => '/phones/new',
  brief: (): string => '/brief',
  briefEdit: (): string => '/brief/edit',
  sources: (): string => '/sources',
  sourcesEdit: (): string => '/sources/edit',
  rules: (): string => '/rules',
  rulesEdit: (): string => '/rules/edit',
  quietHours: (): string => '/rules/quiet-hours',
  deny: (id: string): string => '/rules/deny/' + seg(id),
  notes: (): string => '/notes',
  note: (id: string, version?: string): string => '/notes/' + seg(id) + (version === undefined ? '' : '?version=' + seg(version)),
  noteLog: (id: string): string => '/notes/' + seg(id) + '/log',
  /** Approval on Settings; `auto_approve` opens it with that choice selected and saves nothing. */
  approvalEdit: (setting?: 'auto_approve'): string => '/settings/approval' + (setting === undefined ? '' : '?setting=' + setting),
  firstNote: (): string => '/notes/first',
  /** While Paused the whole app is this page. */
  paused: (): string => '/paused',
  /** The phone web app, which the mailing relay serves on its own origin. */
  phone: (): string => '/app',
  phoneAsk: (hash: string): string => '/app/asks/' + seg(hash),
  phonePair: (): string => '/app/pair'
};
