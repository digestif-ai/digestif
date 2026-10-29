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
  brief: (): string => '/brief',
  briefEdit: (): string => '/brief/edit',
  sources: (): string => '/sources',
  sourcesEdit: (): string => '/sources/edit',
  rules: (): string => '/rules',
  rulesEdit: (): string => '/rules/edit',
  deny: (id: string): string => '/rules/deny/' + seg(id),
  approvals: (): string => '/approvals',
  approval: (hash: string): string => '/approvals/' + seg(hash)
};
