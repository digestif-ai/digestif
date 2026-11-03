import type {
  Agent,
  AgentCheck,
  Approval,
  ApprovalSetting,
  Ask,
  AskStatus,
  AskSummary,
  Brief,
  BriefDraft,
  Device,
  DenyEntry,
  DenyEntryKind,
  FeedItem,
  Invitee,
  Learnings,
  Member,
  MemberSummary,
  Names,
  NamesForm,
  LogEntry,
  Message,
  Note,
  NodeError,
  NodeStatus,
  NoteEditForm,
  Notes,
  NoteTime,
  Paused,
  PhoneForm,
  PostForm,
  Problem,
  QuietHours,
  Rules,
  Source,
  SourceForm
} from '#generated/com-bryzek-digestif-node.ts';
import { withPage, type PageQuery } from '#lib/paging.ts';

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
  asks(status?: AskStatus, page?: PageQuery): Promise<ApiResponse<AskSummary[]>>;
  ask(id: string): Promise<ApiResponse<Ask>>;
  answer(id: string, optionId: string): Promise<ApiResponse<Ask>>;
  members(page?: PageQuery): Promise<ApiResponse<MemberSummary[]>>;
  invitees(): Promise<ApiResponse<Invitee[]>>;
  member(identity: string): Promise<ApiResponse<Member>>;
  mute(identity: string, muted: boolean): Promise<ApiResponse<Member>>;
  addPhone(form: PhoneForm): Promise<ApiResponse<Device>>;
  revokePhone(key: string, recoveryPhrase: string): Promise<ApiResponse<Device>>;
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
  denyList(page?: PageQuery): Promise<ApiResponse<DenyEntry[]>>;
  denyEntry(id: string): Promise<ApiResponse<DenyEntry>>;
  addDeny(kind: DenyEntryKind, value: string): Promise<ApiResponse<DenyEntry>>;
  removeDeny(id: string): Promise<ApiResponse<undefined>>;
  notes(page?: PageQuery): Promise<ApiResponse<Notes>>;
  note(id: string, version?: string): Promise<ApiResponse<Note>>;
  noteLog(id: string): Promise<ApiResponse<LogEntry[]>>;
  editNote(id: string, form: NoteEditForm): Promise<ApiResponse<Note>>;
  approveNote(id: string, versionId: string): Promise<ApiResponse<Note>>;
  dismissSuggestion(): Promise<ApiResponse<undefined>>;
  paused(): Promise<ApiResponse<Paused>>;
  pause(): Promise<ApiResponse<Paused>>;
  unpause(): Promise<ApiResponse<undefined>>;
  problems(open?: boolean): Promise<ApiResponse<Problem[]>>;
  approvalSetting(): Promise<ApiResponse<Approval>>;
  saveApprovalSetting(setting: ApprovalSetting): Promise<ApiResponse<Approval>>;
  learnings(): Promise<ApiResponse<Learnings>>;
  saveLearnings(text: string): Promise<ApiResponse<Learnings>>;
  noteTime(): Promise<ApiResponse<NoteTime>>;
  saveNoteTime(time: string): Promise<ApiResponse<NoteTime>>;
  names(): Promise<ApiResponse<Names>>;
  saveNames(form: NamesForm): Promise<ApiResponse<Names>>;
  agent(): Promise<ApiResponse<Agent>>;
  /** Starts the agent check and answers at once; agentCheck reads it until it ends. */
  saveAgent(path: string): Promise<ApiResponse<AgentCheck>>;
  agentCheck(): Promise<ApiResponse<AgentCheck>>;
}

export function createClient(fetchFn: Fetch = fetch): Client {
  const get = <T>(url: string): Promise<ApiResponse<T>> => request<T>(fetchFn, 'GET', url);
  const send = <T>(method: string, url: string, body?: unknown): Promise<ApiResponse<T>> => request<T>(fetchFn, method, url, body);
  return {
    status: () => get(path('status')),
    feed: () => get(path('feed')),
    message: (hash) => get(path('messages', hash)),
    post: (form) => send('POST', path('messages'), form),
    asks: (status, page) => get(withPage(path('asks') + (status === undefined ? '' : '?status=' + status), page)),
    ask: (id) => get(path('asks', id)),
    answer: (id, optionId) => send('POST', path('asks', id, 'answers'), { option_id: optionId }),
    members: (page) => get(withPage(path('members'), page)),
    invitees: () => get(path('invitees')),
    member: (identity) => get(path('members', identity)),
    mute: (identity, muted) => send('PUT', path('members', identity, 'mute'), { muted: muted }),
    addPhone: (form) => send('POST', path('phones'), form),
    revokePhone: (key, recoveryPhrase) => send('POST', path('phones', key, 'revocations'), { recovery_phrase: recoveryPhrase }),
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
    denyList: (page) => get(withPage(path('rules', 'deny'), page)),
    denyEntry: (id) => get(path('rules', 'deny', id)),
    addDeny: (kind, value) => send('POST', path('rules', 'deny'), { kind: kind, value: value }),
    removeDeny: (id) => send('DELETE', path('rules', 'deny', id)),
    notes: (page) => get(withPage(path('notes'), page)),
    note: (id, version) => get(path('notes', id) + (version === undefined ? '' : '?version=' + encodeURIComponent(version))),
    noteLog: (id) => get(path('notes', id, 'log')),
    editNote: (id, form) => send('POST', path('notes', id, 'versions'), form),
    approveNote: (id, versionId) => send('POST', path('notes', id, 'approve'), { version_id: versionId }),
    dismissSuggestion: () => send('POST', path('notes', 'suggestion', 'dismiss')),
    paused: () => get(path('paused')),
    pause: () => send('POST', path('paused')),
    unpause: () => send('DELETE', path('paused')),
    problems: (open) => get(path('problems') + (open === true ? '?open=true' : '')),
    approvalSetting: () => get(path('settings', 'approval')),
    saveApprovalSetting: (setting) => send('PUT', path('settings', 'approval'), { setting: setting }),
    learnings: () => get(path('learnings')),
    saveLearnings: (text) => send('PUT', path('learnings'), { text: text }),
    noteTime: () => get(path('settings', 'note_time')),
    saveNoteTime: (time) => send('PUT', path('settings', 'note_time'), { time: time }),
    names: () => get(path('settings', 'names')),
    saveNames: (form) => send('PUT', path('settings', 'names'), form),
    agent: () => get(path('settings', 'agent')),
    saveAgent: (agentPath) => send('PUT', path('settings', 'agent'), { path: agentPath }),
    agentCheck: () => get(path('settings', 'agent', 'check'))
  };
}
