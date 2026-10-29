import type {
  ApprovalQueue,
  Ask,
  AskStatus,
  AskSummary,
  Brief,
  DenyEntry,
  DenyEntryKind,
  Dinner,
  DinnerSummary,
  FeedItem,
  Member,
  MemberSummary,
  Message,
  NodeError,
  NodeStatus,
  NotePreview,
  PostForm,
  Rules,
  Source
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
  dinners(): Promise<ApiResponse<DinnerSummary[]>>;
  dinner(hash: string): Promise<ApiResponse<Dinner>>;
  brief(): Promise<ApiResponse<Brief>>;
  saveBrief(text: string): Promise<ApiResponse<Brief>>;
  sources(): Promise<ApiResponse<Source[]>>;
  saveSources(selected: string[]): Promise<ApiResponse<Source[]>>;
  preview(selected: string[]): Promise<ApiResponse<NotePreview>>;
  rules(): Promise<ApiResponse<Rules>>;
  saveRules(text: string): Promise<ApiResponse<Rules>>;
  denyEntry(id: string): Promise<ApiResponse<DenyEntry>>;
  addDeny(kind: DenyEntryKind, value: string): Promise<ApiResponse<DenyEntry>>;
  removeDeny(id: string): Promise<ApiResponse<undefined>>;
  approvals(): Promise<ApiResponse<ApprovalQueue>>;
  approval(hash: string): Promise<ApiResponse<Message>>;
  approve(hash: string): Promise<ApiResponse<Message>>;
  refuse(hash: string): Promise<ApiResponse<Message>>;
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
    dinners: () => get(path('dinners')),
    dinner: (hash) => get(path('dinners', hash)),
    brief: () => get(path('brief')),
    saveBrief: (text) => send('PUT', path('brief'), { text: text }),
    sources: () => get(path('sources')),
    saveSources: (selected) => send('PUT', path('sources'), { selected: selected }),
    preview: (selected) => send('POST', path('sources', 'preview'), { selected: selected }),
    rules: () => get(path('rules')),
    saveRules: (text) => send('PUT', path('rules'), { text: text }),
    denyEntry: (id) => get(path('rules', 'deny', id)),
    addDeny: (kind, value) => send('POST', path('rules', 'deny'), { kind: kind, value: value }),
    removeDeny: (id) => send('DELETE', path('rules', 'deny', id)),
    approvals: () => get(path('approvals')),
    approval: (hash) => get(path('approvals', hash)),
    approve: (hash) => send('POST', path('approvals', hash, 'approve')),
    refuse: (hash) => send('POST', path('approvals', hash, 'refuse'))
  };
}
