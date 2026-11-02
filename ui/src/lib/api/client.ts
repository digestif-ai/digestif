import type {
  Ask,
  AskStatus,
  AskSummary,
  Brief,
  BriefDraft,
  Device,
  DenyEntry,
  DenyEntryKind,
  Dinner,
  DinnerSummary,
  FeedItem,
  Member,
  MemberSummary,
  LogEntry,
  Message,
  Note,
  NodeError,
  NodeStatus,
  NoteEditForm,
  Notes,
  PhoneForm,
  PostForm,
  Problem,
  QuietHours,
  Rules,
  Source,
  SourceForm
} from '#generated/com-bryzek-digestif-node.ts';

/** Every call answers data or errors, never throws on an HTTP status. */
export type ApiResponse<T> = { data: T; status: number } | { errors: NodeError[]; status: number };

export function isApiError<T>(response: ApiResponse<T>): response is { errors: NodeError[]; status: number } {
  return 'errors' in response;
}

type Fetch = typeof fetch;

/** The node serves the API on the UI's own origin; the phone web app passes the relay's base. */
export const API_BASE = '/api/v0';

export function path(...segments: string[]): string {
  return [API_BASE, ...segments.map((s) => encodeURIComponent(s))].join('/');
}

async function parseErrors(response: Response): Promise<NodeError[]> {
  try {
    const body: unknown = await response.json();
    if (Array.isArray(body)) return body as NodeError[];
    if (body !== null && typeof body === 'object' && 'message' in body) return [body as NodeError];
  } catch {
    // fall through to the status line
  }
  return [{ code: 'http_' + String(response.status), message: response.statusText || 'The node did not answer.' }];
}

export async function request<T>(fetchFn: Fetch, method: string, url: string, body?: unknown): Promise<ApiResponse<T>> {
  let response: Response;
  try {
    response = await fetchFn(url, {
      method,
      credentials: 'same-origin',
      headers: { 'Digestif-Local': '1', ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
      ...(body === undefined ? {} : { body: JSON.stringify(body) })
    });
  } catch {
    return { errors: [{ code: 'unreachable', message: 'The node is not running.' }], status: 0 };
  }
  if (!response.ok) return { errors: await parseErrors(response), status: response.status };
  if (response.status === 204) return { data: undefined as T, status: 204 };
  return { data: (await response.json()) as T, status: response.status };
}

export interface Client {
  status(): Promise<ApiResponse<NodeStatus>>;
  feed(): Promise<ApiResponse<FeedItem[]>>;
  message(hash: string): Promise<ApiResponse<Message>>;
  post(form: PostForm): Promise<ApiResponse<Message>>;
  asks(status?: AskStatus): Promise<ApiResponse<AskSummary[]>>;
  ask(id: string): Promise<ApiResponse<Ask>>;
  answer(id: string, optionId: string): Promise<ApiResponse<Ask>>;
  members(): Promise<ApiResponse<MemberSummary[]>>;
  member(identity: string): Promise<ApiResponse<Member>>;
  mute(identity: string, muted: boolean): Promise<ApiResponse<Member>>;
  addPhone(form: PhoneForm): Promise<ApiResponse<Device>>;
  dinners(): Promise<ApiResponse<DinnerSummary[]>>;
  dinner(hash: string): Promise<ApiResponse<Dinner>>;
  brief(): Promise<ApiResponse<Brief>>;
  saveBrief(text: string): Promise<ApiResponse<Brief>>;
  draftBrief(): Promise<ApiResponse<BriefDraft>>;
  sources(): Promise<ApiResponse<Source[]>>;
  saveSources(selected: string[]): Promise<ApiResponse<Source[]>>;
  addSource(form: SourceForm): Promise<ApiResponse<Source[]>>;
  removeSource(id: string): Promise<ApiResponse<Source[]>>;
  rules(): Promise<ApiResponse<Rules>>;
  saveRules(text: string): Promise<ApiResponse<Rules>>;
  saveQuietHours(start: string, end: string): Promise<ApiResponse<QuietHours>>;
  clearQuietHours(): Promise<ApiResponse<undefined>>;
  denyEntry(id: string): Promise<ApiResponse<DenyEntry>>;
  addDeny(kind: DenyEntryKind, value: string): Promise<ApiResponse<DenyEntry>>;
  removeDeny(id: string): Promise<ApiResponse<undefined>>;
  notes(): Promise<ApiResponse<Notes>>;
  note(id: string, version?: string): Promise<ApiResponse<Note>>;
  noteLog(id: string): Promise<ApiResponse<LogEntry[]>>;
  editNote(id: string, form: NoteEditForm): Promise<ApiResponse<Note>>;
  approveNote(id: string, versionId: string): Promise<ApiResponse<Note>>;
  dismissSuggestion(): Promise<ApiResponse<undefined>>;
  problems(open?: boolean): Promise<ApiResponse<Problem[]>>;
}

export function createClient(fetchFn: Fetch = fetch): Client {
  const get = <T>(url: string): Promise<ApiResponse<T>> => request<T>(fetchFn, 'GET', url);
  const send = <T>(method: string, url: string, body?: unknown): Promise<ApiResponse<T>> => request<T>(fetchFn, method, url, body);
  return {
    status: () => get(path('status')),
    feed: () => get(path('feed')),
    message: (hash) => get(path('messages', hash)),
    post: (form) => send('POST', path('messages'), form),
    asks: (status) => get(path('asks') + (status === undefined ? '' : '?status=' + status)),
    ask: (id) => get(path('asks', id)),
    answer: (id, optionId) => send('POST', path('asks', id, 'answers'), { option_id: optionId }),
    members: () => get(path('members')),
    member: (identity) => get(path('members', identity)),
    mute: (identity, muted) => send('PUT', path('members', identity, 'mute'), { muted: muted }),
    addPhone: (form) => send('POST', path('phones'), form),
    dinners: () => get(path('dinners')),
    dinner: (hash) => get(path('dinners', hash)),
    brief: () => get(path('brief')),
    saveBrief: (text) => send('PUT', path('brief'), { text: text }),
    draftBrief: () => send('POST', path('brief', 'draft')),
    sources: () => get(path('sources')),
    saveSources: (selected) => send('PUT', path('sources'), { selected: selected }),
    addSource: (form) => send('POST', path('sources'), form),
    removeSource: (id) => send('DELETE', path('sources', id)),
    rules: () => get(path('rules')),
    saveRules: (text) => send('PUT', path('rules'), { text: text }),
    saveQuietHours: (start, end) => send('PUT', path('rules', 'quiet_hours'), { start: start, end: end }),
    clearQuietHours: () => send('DELETE', path('rules', 'quiet_hours')),
    denyEntry: (id) => get(path('rules', 'deny', id)),
    addDeny: (kind, value) => send('POST', path('rules', 'deny'), { kind: kind, value: value }),
    removeDeny: (id) => send('DELETE', path('rules', 'deny', id)),
    notes: () => get(path('notes')),
    note: (id, version) => get(path('notes', id) + (version === undefined ? '' : '?version=' + encodeURIComponent(version))),
    noteLog: (id) => get(path('notes', id, 'log')),
    editNote: (id, form) => send('POST', path('notes', id, 'versions'), form),
    approveNote: (id, versionId) => send('POST', path('notes', id, 'approve'), { version_id: versionId }),
    dismissSuggestion: () => send('POST', path('notes', 'suggestion', 'dismiss')),
    problems: (open) => get(path('problems') + (open === true ? '?open=true' : ''))
  };
}
