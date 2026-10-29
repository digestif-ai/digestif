// An in-memory node answering spec/digestif-node.json, for `npm run dev` without a node and for the
// tests. It implements the contract's rules (deny layer trips, first-five approval, mute) loosely
// enough to drive every screen, and is never part of the build.
import {
  type Ask,
  AskStatus,
  type DenyEntryKind,
  type Dinner,
  type DinnerSummary,
  type FeedItem,
  type Member,
  type MemberSummary,
  type Message,
  MessageStatus,
  type NodeError,
  Voice
} from '#generated/com-bryzek-digestif-node.ts';
import { seed, type Store } from './fixtures.ts';

export interface MockResponse {
  status: number;
  body?: unknown;
}

const err = (status: number, code: string, message: string, field?: string): MockResponse => ({
  status,
  body: [{ code, message, ...(field === undefined ? {} : { field: field }) } satisfies NodeError]
});
const notFound = (): MockResponse => err(404, 'not_found', 'Not found.');
const ok = (body: unknown, status = 200): MockResponse => ({ status, body });

const SECRET = /(sk-[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|[a-z]+:\/\/[^\s:]+:[^\s@]+@)/;

function item(m: Message): FeedItem {
  const preview = (m.text ?? (m.status === 'refused' ? 'Refused before signing' : 'Sealed')).split('\n')[0] ?? '';
  return {
    hash: m.hash,
    kind: m.kind,
    voice: m.voice,
    author: m.author,
    ...(m.recipient === undefined ? {} : { recipient: m.recipient }),
    created_at: m.created_at,
    status: m.status,
    preview: preview.slice(0, 140)
  };
}

function summary(m: Member): MemberSummary {
  const { joined_at: _j, devices: _d, recent: _r, ...rest } = m;
  return rest;
}

function denyTrip(store: Store, text: string): string | undefined {
  for (const entry of store.deny) {
    const hit = entry.kind === 'pattern' ? new RegExp(entry.value, 'i').test(text) : text.toLowerCase().includes(entry.value.toLowerCase());
    if (hit) {
      entry.trips += 1;
      return 'deny: ' + entry.kind;
    }
  }
  return SECRET.test(text) ? 'detector: secret shape' : undefined;
}

function nextHash(store: Store): string {
  store.nextId += 1;
  return 'sha256:' + store.nextId.toString(16).padStart(64, '0');
}

function str(body: unknown, field: string): string | undefined {
  if (body === null || typeof body !== 'object') return undefined;
  const v = (body as Record<string, unknown>)[field];
  return typeof v === 'string' ? v : undefined;
}

function strings(body: unknown, field: string): string[] | undefined {
  if (body === null || typeof body !== 'object') return undefined;
  const v = (body as Record<string, unknown>)[field];
  return Array.isArray(v) && v.every((x) => typeof x === 'string') ? v : undefined;
}

function match(pattern: string, parts: string[]): string[] | undefined {
  const ps = pattern.split('/');
  if (ps.length !== parts.length) return undefined;
  const params: string[] = [];
  for (let i = 0; i < ps.length; i++) {
    const part = parts[i] ?? '';
    if (ps[i] === ':') params.push(part);
    else if (ps[i] !== part) return undefined;
  }
  return params;
}

function withFound<T>(value: T | undefined, run: (v: T) => MockResponse): MockResponse {
  return value === undefined ? notFound() : run(value);
}

function dinnerSummary(d: Dinner): DinnerSummary {
  return {
    hash: d.hash,
    date: d.date,
    label: d.label,
    host: d.host,
    guests: d.guests.length,
    joined: d.guests.filter((g) => g.status === 'joined').length
  };
}

export class MockNode {
  store: Store;

  constructor(now: Date = new Date()) {
    this.store = seed(now);
  }

  reset(now: Date = new Date()): void {
    this.store = seed(now);
  }

  private self(): Member {
    const me = this.store.members.find((m) => m.identity === this.store.self);
    if (me === undefined) throw new Error('fixture has no self');
    return me;
  }

  private approvalsRequired(): number {
    return Math.max(0, 5 - this.store.approved);
  }

  private detail(m: Message): Message {
    const replies = this.store.messages.filter((r) => r.reply_to === m.hash).map(item);
    return { ...m, replies };
  }

  private member(m: Member): Member {
    const recent = this.store.messages.filter((x) => x.author.identity === m.identity).map(item);
    return { ...m, recent };
  }

  handle(method: string, url: string, body?: unknown): MockResponse {
    const u = new URL(url, 'http://node.local');
    const parts = u.pathname
      .replace(/^\/api\/v0\/?/, '')
      .split('/')
      .filter((p) => p !== '')
      .map(decodeURIComponent);
    for (const [verb, pattern, run] of this.routes()) {
      if (verb !== method) continue;
      const params = match(pattern, parts);
      if (params !== undefined) return run(params, body, u.searchParams);
    }
    return notFound();
  }

  private routes(): [string, string, (p: string[], body: unknown, q: URLSearchParams) => MockResponse][] {
    const s = this.store;
    const message = (hash: string | undefined): Message | undefined => s.messages.find((x) => x.hash === hash);
    const mine = (hash: string | undefined): Message | undefined => s.messages.find((x) => x.hash === hash && x.author.identity === s.self);
    const memberOf = (identity: string | undefined): Member | undefined => s.members.find((x) => x.identity === identity);
    return [
      ['GET', 'status', () => this.status()],
      ['GET', 'feed', () => ok([...s.messages].sort((x, y) => y.created_at.localeCompare(x.created_at)).map(item))],
      ['GET', 'messages/:', ([h]) => withFound(message(h), (m) => ok(this.detail(m)))],
      ['POST', 'messages', (_p, b) => this.post(b)],
      ['GET', 'asks', (_p, _b, q) => this.asks(q.get('status') as AskStatus | null)],
      [
        'GET',
        'asks/:',
        ([id]) =>
          withFound(
            s.asks.find((x) => x.id === id),
            (x) => ok(x)
          )
      ],
      [
        'POST',
        'asks/:/answers',
        ([id], b) =>
          withFound(
            s.asks.find((x) => x.id === id),
            (x) => this.answer(x, b)
          )
      ],
      [
        'GET',
        'members',
        () =>
          ok(
            [...s.members]
              .sort((x, y) => (y.last_posted_at ?? '').localeCompare(x.last_posted_at ?? ''))
              .map((m) => summary(this.member(m)))
          )
      ],
      ['GET', 'members/:', ([id]) => withFound(memberOf(id), (m) => ok(this.member(m)))],
      [
        'PUT',
        'members/:/mute',
        ([id], b) =>
          withFound(memberOf(id), (m) => {
            if (m.is_self) return err(422, 'self', 'You cannot mute yourself.');
            m.muted = (b as { muted?: unknown } | undefined)?.muted === true;
            return ok(this.member(m));
          })
      ],
      ['GET', 'dinners', () => ok(s.dinners.map(dinnerSummary))],
      [
        'GET',
        'dinners/:',
        ([h]) =>
          withFound(
            s.dinners.find((x) => x.hash === h),
            (d) => ok(d)
          )
      ],
      ['GET', 'brief', () => ok(s.brief)],
      ['PUT', 'brief', (_p, b) => this.saveBrief(b)],
      ['GET', 'sources', () => ok(s.sources)],
      ['PUT', 'sources', (_p, b) => this.saveSources(b)],
      ['POST', 'sources/preview', (_p, b) => this.preview(b)],
      ['GET', 'rules', () => ok(this.rules())],
      [
        'PUT',
        'rules',
        (_p, b) => {
          s.rulesText = str(b, 'text') ?? '';
          s.rulesUpdatedAt = new Date().toISOString();
          return ok(this.rules());
        }
      ],
      ['POST', 'rules/deny', (_p, b) => this.addDeny(b)],
      [
        'GET',
        'rules/deny/:',
        ([id]) =>
          withFound(
            s.deny.find((x) => x.id === id),
            (e) => ok(e)
          )
      ],
      [
        'DELETE',
        'rules/deny/:',
        ([id]) => {
          const i = s.deny.findIndex((x) => x.id === id);
          if (i < 0) return notFound();
          s.deny.splice(i, 1);
          return { status: 204 };
        }
      ],
      ['GET', 'approvals', () => this.approvals()],
      ['GET', 'approvals/:', ([h]) => withFound(mine(h), (m) => ok(this.detail(m)))],
      ['POST', 'approvals/:/approve', ([h]) => withFound(mine(h), (m) => this.decide(m, true))],
      ['POST', 'approvals/:/refuse', ([h]) => withFound(mine(h), (m) => this.decide(m, false))]
    ];
  }

  private status(): MockResponse {
    const s = this.store;
    const me = this.self();
    return ok({
      member_name: me.name,
      agent_name: me.agent_name,
      first_run: s.firstRun,
      open_asks: s.asks.filter((x) => x.status === 'open').length,
      notes_awaiting_approval: s.messages.filter((m) => m.status === 'awaiting_approval').length,
      approvals_required: this.approvalsRequired()
    });
  }

  private post(body: unknown): MockResponse {
    const s = this.store;
    const text = (str(body, 'text') ?? '').trim();
    if (text === '') return err(422, 'empty', 'Write something first.', 'text');
    const replyTo = str(body, 'reply_to');
    const parent = replyTo === undefined ? undefined : s.messages.find((x) => x.hash === replyTo);
    if (replyTo !== undefined && parent === undefined) return err(422, 'unknown_reply_to', 'That message is gone.', 'reply_to');
    const me = this.self();
    const rule = denyTrip(s, text);
    const m: Message = {
      hash: nextHash(s),
      kind: parent === undefined ? 'summary' : 'answer',
      voice: Voice.Person,
      author: { identity: me.identity, name: me.name, agent_name: me.agent_name },
      ...(parent === undefined || parent.author.identity === me.identity ? {} : { recipient: parent.author }),
      created_at: new Date().toISOString(),
      status: rule === undefined ? MessageStatus.Posted : MessageStatus.Refused,
      ...(rule === undefined ? { text: text } : { refused_rule: rule }),
      ...(replyTo === undefined ? {} : { reply_to: replyTo }),
      replies: []
    };
    s.messages.push(m);
    if (rule === undefined) me.last_posted_at = m.created_at;
    return ok(m, 201);
  }

  private asks(status: AskStatus | null): MockResponse {
    const rank = (x: { status: string }): number => (x.status === 'open' ? 0 : 1);
    return ok(
      this.store.asks
        .filter((x) => status === null || x.status === status)
        .sort((x, y) => rank(x) - rank(y) || y.created_at.localeCompare(x.created_at))
        .map(({ detail: _d, options: _o, on_no_answer: _n, message: _m, answer: _a, ...rest }) => rest)
    );
  }

  private answer(x: Ask, body: unknown): MockResponse {
    const optionId = str(body, 'option_id');
    if (x.status !== 'open') return err(422, 'not_open', 'This ask is no longer open.');
    if (optionId === undefined || !x.options.some((o) => o.id === optionId))
      return err(422, 'unknown_option', 'No such option.', 'option_id');
    x.status = AskStatus.Answered;
    x.answer = { option_id: optionId, answered_at: new Date().toISOString() };
    return ok(x, 201);
  }

  private saveBrief(body: unknown): MockResponse {
    const text = (str(body, 'text') ?? '').trim();
    if (text === '') return err(422, 'empty', 'Write a few lines about yourself.', 'text');
    this.store.brief = { text, updated_at: new Date().toISOString() };
    return ok(this.store.brief);
  }

  private knownSelection(body: unknown): string[] | undefined {
    const selected = strings(body, 'selected');
    return selected === undefined || selected.some((id) => !this.store.sources.some((x) => x.id === id)) ? undefined : selected;
  }

  private saveSources(body: unknown): MockResponse {
    const selected = this.knownSelection(body);
    if (selected === undefined) return err(422, 'unknown_source', 'Unknown source.', 'selected');
    this.store.sources = this.store.sources.map((x) => ({ ...x, selected: selected.includes(x.id) }));
    this.store.firstRun = false;
    return ok(this.store.sources);
  }

  private preview(body: unknown): MockResponse {
    const selected = this.knownSelection(body);
    if (selected === undefined) return err(422, 'unknown_source', 'Unknown source.', 'selected');
    if (selected.length === 0) return ok({ extracted: [] });
    const extracted = selected.flatMap((id) =>
      id === 'git' ? ['commit: Add a retry queue to the importer', 'commit: Batch writes in the loader'] : ['session: Speed up the loader']
    );
    const text =
      'Worked on: speeding up the loader and a retry queue.\nLearned: batching writes halves the lock time.\nStuck on: nothing yet.';
    const rule = denyTrip(this.store, text);
    return ok(rule === undefined ? { text, extracted } : { refused_rule: rule, extracted });
  }

  private approvals(): MockResponse {
    const s = this.store;
    const waiting = (m: Message): number => (m.status === 'awaiting_approval' ? 0 : 1);
    return ok({
      approved: s.approved,
      required: 5,
      notes: s.messages
        .filter((m) => m.author.identity === s.self && m.kind === 'summary' && m.voice === 'agent')
        .sort((x, y) => waiting(x) - waiting(y) || y.created_at.localeCompare(x.created_at))
        .map(item)
    });
  }

  private decide(m: Message, approve: boolean): MockResponse {
    if (m.status !== 'awaiting_approval') return err(422, 'not_awaiting', 'This note was already decided.');
    if (approve) {
      m.status = MessageStatus.Posted;
      this.store.approved += 1;
      this.self().last_posted_at = new Date().toISOString();
    } else {
      m.status = MessageStatus.Retracted;
      delete m.text;
    }
    return ok(this.detail(m));
  }

  private rules(): unknown {
    const s = this.store;
    return {
      text: s.rulesText,
      ...(s.rulesUpdatedAt === undefined ? {} : { updated_at: s.rulesUpdatedAt }),
      deny: s.deny,
      detectors: s.detectors
    };
  }

  private addDeny(body: unknown): MockResponse {
    const s = this.store;
    const kind = str(body, 'kind') as DenyEntryKind | undefined;
    const value = (str(body, 'value') ?? '').trim();
    if (kind === undefined || !['name', 'domain', 'id', 'pattern'].includes(kind)) return err(422, 'kind', 'Choose a kind.', 'kind');
    if (value === '') return err(422, 'empty', 'Enter a value.', 'value');
    if (kind === 'pattern') {
      try {
        new RegExp(value);
      } catch {
        return err(422, 'pattern', 'That pattern does not compile.', 'value');
      }
    }
    if (s.deny.some((e) => e.kind === kind && e.value === value)) return err(422, 'duplicate', 'Already on the list.', 'value');
    s.nextId += 1;
    const entry = { id: 'deny-' + String(s.nextId), kind, value, created_at: new Date().toISOString(), trips: 0 };
    s.deny.push(entry);
    return ok(entry, 201);
  }
}
