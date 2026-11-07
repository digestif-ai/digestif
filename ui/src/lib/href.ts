/** Every page address in one place, so list rows and breadcrumbs agree. */
const seg = (s: string): string => encodeURIComponent(s);

export const href = {
  feed: (): string => '/feed',
  /** A message; a note is approved on its own (ISS-47299), so `version` names the version read. */
  message: (hash: string, version?: string): string => '/feed/' + seg(hash) + (version === undefined ? '' : '?version=' + seg(version)),
  /** The form that posts to the whole circle as the person. */
  post: (): string => '/feed/new',
  /** The Inbox: every item the member wrote and every item addressed to them (DES-51007). */
  inbox: (status?: string): string => '/inbox' + (status === undefined ? '' : '?status=' + seg(status)),
  item: (id: string): string => '/inbox/' + seg(id),
  newItem: (): string => '/inbox/new',
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
  /** What the member's agent does with everything that reaches them (ISS-52611). */
  inboxAgent: (): string => '/settings/inbox-agent',
  inboxAgentEdit: (): string => '/settings/inbox-agent/edit',
  noteTimeEdit: (): string => '/settings/note-time',
  digestEdit: (): string => '/settings/digest',
  quietHours: (): string => '/settings/quiet-hours',
  /** The circle's nightly note prompt and every suggestion to change it (ISS-51009). */
  notePrompt: (): string => '/settings/note-prompt',
  suggestPrompt: (): string => '/settings/note-prompt/new',
  promptSuggestion: (hash: string): string => '/settings/note-prompt/' + seg(hash),
  phones: (): string => '/settings/phones',
  phoneNew: (): string => '/settings/phones/new',
  /** One phone; its Remove is a mode of this page. */
  phoneDetail: (key: string): string => '/settings/phones/' + seg(key),
  /** A note is read, approved and edited on its message (ISS-47299). */
  note: (id: string, version?: string): string => '/feed/' + seg(id) + (version === undefined ? '' : '?version=' + seg(version)),
  /** While Paused the whole app is this page. */
  paused: (): string => '/paused',
  /** The phone web app, which the mailing relay serves on its own origin. */
  phone: (): string => '/app',
  phoneItem: (hash: string): string => '/app/items/' + seg(hash),
  phonePair: (): string => '/app/pair'
};
