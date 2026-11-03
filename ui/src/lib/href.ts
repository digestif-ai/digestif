/** Every page address in one place, so list rows and breadcrumbs agree. */
const seg = (s: string): string => encodeURIComponent(s);

export const href = {
  feed: (): string => '/feed',
  message: (hash: string): string => '/feed/' + seg(hash),
  asks: (): string => '/asks',
  ask: (id: string): string => '/asks/' + seg(id),
  /** The page an Asks row opens: a local ask is answered on the page it asks about, never on its own
   * (DES-37153); every other ask opens its own page. */
  askRow: (ask: { id: string; kind: string }): string =>
    ask.kind === 'repositories' ? '/settings/repositories/edit?status=undecided' : '/asks/' + seg(ask.id),
  members: (): string => '/members',
  member: (identity: string): string => '/members/' + seg(identity),
  /** Settings is one page; each of its sections has an edit page under it. */
  settings: (): string => '/settings',
  sourcesEdit: (): string => '/settings/sources',
  settingsRepositories: (status?: string): string => '/settings/repositories/edit' + (status === undefined ? '' : '?status=' + seg(status)),
  briefEdit: (): string => '/settings/brief',
  rulesEdit: (): string => '/settings/rules',
  learningsEdit: (): string => '/settings/learnings',
  denyList: (): string => '/settings/deny',
  deny: (id: string): string => '/settings/deny/' + seg(id),
  /** Approval on Settings; `auto_approve` opens it with that choice selected and saves nothing. */
  approvalEdit: (setting?: 'auto_approve'): string => '/settings/approval' + (setting === undefined ? '' : '?setting=' + setting),
  namesEdit: (): string => '/settings/names',
  agentEdit: (): string => '/settings/agent',
  noteTimeEdit: (): string => '/settings/note-time',
  quietHours: (): string => '/settings/quiet-hours',
  phones: (): string => '/settings/phones',
  phoneNew: (): string => '/settings/phones/new',
  /** One phone; its Remove is a mode of this page. */
  phoneDetail: (key: string): string => '/settings/phones/' + seg(key),
  notes: (): string => '/notes',
  note: (id: string, version?: string): string => '/notes/' + seg(id) + (version === undefined ? '' : '?version=' + seg(version)),
  noteLog: (id: string): string => '/notes/' + seg(id) + '/log',
  /** While Paused the whole app is this page. */
  paused: (): string => '/paused',
  /** The phone web app, which the mailing relay serves on its own origin. */
  phone: (): string => '/app',
  phoneAsk: (hash: string): string => '/app/asks/' + seg(hash),
  phonePair: (): string => '/app/pair'
};
