// An in-memory node answering spec/digestif-node.json, for `npm run dev` without a node and for the
// tests. It implements the contract's rules (deny layer trips, notes and their approval, mute) loosely
// enough to drive every screen, and is never part of the build.
import { createHash } from 'node:crypto';
import {
  type AgentCheck,
  AgentCheckStatus,
  type Ask,
  AskKind,
  AskStatus,
  RepositoryStatus,
  type DenyEntryKind,
  type FeedItem,
  type Member,
  type MemberSummary,
  type Note,
  NoteStatus,
  type NoteProgress,
  NoteProgressState,
  type NoteSummary,
  CheckState,
  type Paused,
  PauseReason,
  type PauseWarning,
  type Problem,
  type Message,
  MessageStatus,
  type NodeError,
  type QuietHours,
  SourceKind,
  StatusNote,
  Stage,
  PromptPick,
  RoundResult,
  type Suggestion,
  SuggestionStatus,
  type SuggestionSummary,
  Voice
} from '#generated/com-bryzek-digestif-node.ts';
import { seed, type MockMessage, type MockNote, type Store } from './fixtures.ts';
import { MockRepositories } from './repositories.ts';

export interface MockResponse {
  status: number;
  body?: unknown;
}

const err = (status: number, code: string, message: string, field?: string): MockResponse => ({
  status,
  body: [{ code, message, ...(field === undefined ? {} : { field: field }) } satisfies NodeError]
});
const notFound = (): MockResponse => err(404, 'not_found', 'Not found.');
const DAY = 86_400_000;
const ok = (body: unknown, status = 200): MockResponse => ({ status, body });

/**
 * One page of [rows], already in the list's order, as the node's list routes answer it
 * (ISS-41988): a limit, and a cursor naming the last row of the page before.
 */
function page<T>(rows: T[], q: URLSearchParams, idOf: (row: T) => string): MockResponse {
  const limit = Number(q.get('limit') ?? '100');
  if (!Number.isInteger(limit) || limit < 1 || limit > 200) return err(422, 'limit', 'Not a valid limit.', 'limit');
  const cursor = q.get('cursor');
  let start = 0;
  if (cursor !== null && cursor !== '') {
    const i = rows.findIndex((r) => idOf(r) === cursor);
    if (i < 0) return err(422, 'cursor', 'Not a valid cursor.', 'cursor');
    start = i + 1;
  }
  return ok(rows.slice(start, start + limit));
}

const SECRET = /(sk-[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|[a-z]+:\/\/[^\s:]+:[^\s@]+@)/;

// The node's preview (node/web/api.ml, first_line): the first line after the note's section
// headings, a heading on the same line as its text dropped from it.
const HEADING = /^(worked on|learned|stuck on)\s*(?::\s*|$)/i;
function previewLine(text: string): string {
  const line = text
    .split('\n')
    .map((l) => l.trim().replace(HEADING, '').trim())
    .find((l) => l !== '');
  return (line ?? text.split('\n')[0] ?? '').slice(0, 140);
}

function item(m: MockMessage): FeedItem {
  const preview = m.text === undefined ? (m.status === 'refused' ? 'Refused before signing' : 'Sealed') : previewLine(m.text);
  return {
    hash: m.hash,
    kind: m.kind,
    voice: m.voice,
    author: m.author,
    ...(m.recipient === undefined ? {} : { recipient: m.recipient }),
    created_at: m.created_at,
    status: m.status,
    preview,
    ...(m.status_note === undefined ? {} : { status_note: m.status_note })
  };
}

/** Members: Active first, then Paused, then Onboarding, the newest note first within each. */
const STAGE_RANK: Record<string, number> = { active: 0, paused: 1, onboarding: 2 };

function summary(m: Member): MemberSummary {
  const { joined_at: _j, devices: _d, recent: _r, ...rest } = m;
  return rest;
}

function suggestionSummary(s: Suggestion): SuggestionSummary {
  const { hash, author, created_at, change, status, judge, running } = s;
  return { hash, author, created_at, change, status, judge, running };
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

/** The newest version whose checks passed: what a note page shows by default. */
function shown(n: MockNote): MockNote['versions'][number] | undefined {
  return [...n.versions].reverse().find((v) => v.checks.pii === CheckState.Passed && v.checks.rules === CheckState.Passed);
}

function withFound<T>(value: T | undefined, run: (v: T) => MockResponse): MockResponse {
  return value === undefined ? notFound() : run(value);
}

export class MockNode {
  store: Store;
  repositories: MockRepositories;

  constructor(now: Date = new Date()) {
    this.store = seed(now);
    this.repositories = new MockRepositories(now);
  }

  reset(now: Date = new Date()): void {
    this.store = seed(now);
    this.repositories = new MockRepositories(now);
  }

  private self(): Member {
    const me = this.store.members.find((m) => m.identity === this.store.self);
    if (me === undefined) throw new Error('fixture has no self');
    return me;
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
    const noteOf = (id: string | undefined): MockNote | undefined => s.notes.find((n) => n.id === id);
    const memberOf = (identity: string | undefined): Member | undefined => s.members.find((x) => x.identity === identity);
    return [
      ['GET', 'status', () => this.status()],
      ['GET', 'feed', () => ok([...s.messages, ...this.notesInFeed()].sort((x, y) => y.created_at.localeCompare(x.created_at)).map(item))],
      [
        'GET',
        'messages/:',
        ([h]) => {
          const m = message(h);
          if (m !== undefined) return ok(this.detail(m));
          return withFound(noteOf(h), (n) => ok(this.noteMessage(n)));
        }
      ],
      ['POST', 'messages', (_p, b) => this.post(b)],
      ['GET', 'asks', (_p, _b, q) => this.asks(q)],
      [
        'GET',
        'asks/:',
        ([id]) =>
          withFound(
            this.allAsks().find((x) => x.id === id),
            (x) => ok(x)
          )
      ],
      [
        'POST',
        'asks/:/answers',
        ([id], b) =>
          withFound(
            this.allAsks().find((x) => x.id === id),
            (x) => this.answer(x, b)
          )
      ],
      [
        'GET',
        'members',
        (_p, _b, q) =>
          page(
            s.members
              .filter((m) => m.status !== 'revoked')
              .sort(
                (x, y) =>
                  (STAGE_RANK[x.stage] ?? 2) - (STAGE_RANK[y.stage] ?? 2) || (y.last_note_at ?? '').localeCompare(x.last_note_at ?? '')
              )
              .map((m) => summary(this.member(m))),
            q,
            (m) => m.identity
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
      ['POST', 'phones', (_p, b) => this.addPhone(b)],
      ['POST', 'phones/:/revocations', ([key], b) => this.revokePhone(key ?? '', b)],
      ['GET', 'invitees', () => ok(s.invitees)],
      ['GET', 'brief', () => ok({ ...s.brief, can_draft: true })],
      ['POST', 'brief/draft', () => this.draftBrief()],
      ['PUT', 'brief', (_p, b) => this.saveBrief(b)],
      ['GET', 'sources', () => ok(s.sources)],
      ['PUT', 'sources', (_p, b) => this.saveSources(b)],
      ['POST', 'sources', (_p, b) => this.addSource(b)],
      ['POST', '_first_note', (_p, b) => this.setFirstNote(b)],
      ['DELETE', 'sources/:', ([id]) => this.removeSource(id ?? '')],
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
      ['GET', 'rules/quiet_hours', () => withFound(this.quietHours(), (q) => ok(q))],
      ['PUT', 'rules/quiet_hours', (_p, b) => this.saveQuietHours(b)],
      [
        'DELETE',
        'rules/quiet_hours',
        () => {
          delete s.quietHours;
          return { status: 204 };
        }
      ],
      ['GET', 'problems', (_p, _b, q) => ok(q.get('open') === 'true' ? s.problems.filter((p) => p.closed_at === undefined) : s.problems)],
      ['GET', 'rules/deny', (_p, _b, q) => page(s.deny, q, (e) => e.id)],
      ['POST', 'rules/deny', (_p, b) => this.addDeny(b)],
      ['GET', 'settings/digest', () => ok(this.digest())],
      [
        'PUT',
        'settings/digest',
        (_p, b) => {
          const email = (str(b, 'email') ?? '').trim();
          const at = email.indexOf('@');
          if (at <= 0 || at === email.length - 1 || email.lastIndexOf('@') !== at || /\s/.test(email))
            return err(422, 'invalid', 'Enter an email address, such as you@example.com.', 'email');
          const hour = (b as { hour?: unknown } | null)?.hour;
          if (typeof hour !== 'number' || !Number.isInteger(hour) || hour < 0 || hour > 23)
            return err(422, 'invalid', 'The hour is 0 to 23.', 'hour');
          s.digestEmail = email;
          s.digestHour = hour;
          return ok(this.digest());
        }
      ],
      ['GET', 'settings/note_time', () => ok(this.noteTime())],
      [
        'PUT',
        'settings/note_time',
        (_p, b) => {
          const m = /^(\d{1,2}):(\d{2})$/.exec((str(b, 'time') ?? '').trim());
          const h = m === null ? -1 : Number(m[1]);
          const min = m === null ? -1 : Number(m[2]);
          if (h < 0 || h > 23 || min < 0 || min > 59) return err(422, 'invalid', 'Enter a time of day, such as 07:00.', 'time');
          s.noteTime = String(h).padStart(2, '0') + ':' + String(min).padStart(2, '0');
          return ok(this.noteTime());
        }
      ],
      ['GET', 'settings/names', () => ok({ member_name: this.self().name, agent_name: this.self().agent_name, published: true })],
      ['PUT', 'settings/names', (_p, b) => this.saveNames(b)],
      // A check that passed since it was last read saves the agent, as the node's does when it ends.
      ['GET', 'settings/agent', () => (this.agentCheck(), withFound(s.agent, (a) => ok(a)))],
      ['PUT', 'settings/agent', (_p, b) => this.saveAgent(b)],
      ['GET', 'settings/agent/check', () => withFound(this.agentCheck(), (k) => ok(k))],
      ['GET', 'learnings', () => ok(s.learnings)],
      [
        'PUT',
        'learnings',
        (_p, b) => {
          s.learnings = { text: str(b, 'text') ?? '', updated_at: new Date().toISOString() };
          return ok(s.learnings);
        }
      ],
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
      ['GET', 'notes', (_p, _b, q) => this.notes(q)],
      [
        'POST',
        'notes/suggestion/dismiss',
        () => {
          s.unchanged = 0;
          return { status: 204 };
        }
      ],
      ['GET', 'notes/:', ([id], _b, q) => withFound(noteOf(id), (n) => this.note(n, q.get('version') ?? undefined))],
      ['GET', 'notes/:/log', ([id]) => withFound(noteOf(id), (n) => ok(this.noteLog(n)))],
      ['GET', 'notes/:/versions', ([id]) => withFound(noteOf(id), (n) => ok(n.versions.map(({ learned: _l, ...v }) => v)))],
      ['POST', 'notes/:/dismiss', ([id]) => withFound(noteOf(id), (n) => this.dismiss(n))],
      [
        'POST',
        'notes/runs',
        () => {
          s.writeNow = true;
          // A first note no run was writing is being written again (ISS-48141).
          for (const n of s.notes)
            if (n.progress?.state === NoteProgressState.Stopped) n.progress = { state: NoteProgressState.Writing, sources: [] };
          return { status: 202 };
        }
      ],
      ['POST', 'notes/:/versions', ([id], b) => withFound(noteOf(id), (n) => this.edit(n, b))],
      ['POST', 'notes/:/approve', ([id], b) => withFound(noteOf(id), (n) => this.approve(n, b))],
      ['GET', 'paused', () => withFound(this.paused(), (p) => ok(p))],
      ['POST', 'paused', () => this.pause(PauseReason.PressedPause)],
      [
        'DELETE',
        'paused',
        () => {
          if (s.pause === undefined) return notFound();
          delete s.pause;
          s.unpausedAt = new Date().toISOString();
          this.self().stage = Stage.Active;
          return { status: 204 };
        }
      ],
      // For the tests: an open problem, as a job reports it (node/web/api.ml Problems.report).
      [
        'POST',
        '_problem',
        (_p, b) => {
          const at = new Date().toISOString();
          s.nextId += 1;
          s.problems.push({
            id: 'problem-' + String(s.nextId),
            job: (str(b, 'job') ?? 'self_update') as Problem['job'],
            kind: (str(b, 'kind') ?? 'failed') as Problem['kind'],
            first_seen_at: at,
            last_seen_at: at,
            count: 1
          });
          return { status: 204 };
        }
      ],
      // For the tests: a note written [days] ago, so its 30 days are near (the node counts them
      // from its first checked version; the mock from when it was written).
      [
        'POST',
        '_note_age',
        (_p, b) =>
          withFound(noteOf(str(b, 'id')), (n) => {
            n.written_at = new Date(Date.now() - Number((b as { days?: unknown }).days) * DAY).toISOString();
            return this.pauseIfDue() ?? { status: 204 };
          })
      ],
      ['GET', 'settings/approval', () => ok({ setting: s.approval })],
      [
        'PUT',
        'settings/approval',
        (_p, b) => {
          const setting = str(b, 'setting');
          if (setting !== 'every_note_waits' && setting !== 'auto_approve') return err(422, 'setting', 'Choose a setting.', 'setting');
          s.approval = setting;
          if (setting === 'every_note_waits') s.unchanged = 0;
          return ok({ setting, updated_at: new Date().toISOString() });
        }
      ],
      ['GET', 'note_prompt', () => ok(this.notePrompt())],
      ['GET', 'suggestions', (_p, _b, q) => page([...s.suggestions].reverse().map(suggestionSummary), q, (r) => r.hash)],
      [
        'GET',
        'suggestions/:',
        ([h]) =>
          withFound(
            s.suggestions.find((x) => x.hash === h),
            (x) => ok(x)
          )
      ],
      ['POST', 'suggestions', (_p, b) => this.suggest(b)],
      ['DELETE', 'suggestions/:', ([h]) => this.withdraw(h ?? '')],
      // For the tests: the waiting note written in two versions for the suggestion this member judges.
      ['POST', '_note_pair', (_p, b) => withFound(noteOf(str(b, 'id')), (n) => this.pairNote(n))],
      ...this.repositories.routes()
    ];
  }

  private digest(): { email?: string; hour: number } {
    const s = this.store;
    return { ...(s.digestEmail === undefined ? {} : { email: s.digestEmail }), hour: s.digestHour };
  }

  private notePrompt(): unknown {
    const live = this.store.livePrompt;
    const running = this.store.suggestions.find((x) => x.running);
    return {
      ...(live === undefined
        ? {}
        : { text: live.text, id: 'sha256:' + createHash('sha256').update(live.text).digest('hex'), adoption: live.adoption }),
      ...(running === undefined ? {} : { running })
    };
  }

  private suggest(b: unknown): MockResponse {
    const text = (str(b, 'text') ?? '').trim();
    const change = (str(b, 'change') ?? '').trim().replace(/\s+/g, ' ');
    if (text === '') return err(422, 'empty', 'Write the prompt you suggest.', 'text');
    if (!text.includes('{{always_on_rules}}'))
      return err(422, 'always_on', 'The prompt has to include {{always_on_rules}}, where the always-on rule goes.', 'text');
    if (change === '') return err(422, 'empty', 'Say in one line what it changes.', 'change');
    if (text === this.store.livePrompt?.text) return err(422, 'unchanged', 'This is the prompt that stands now.', 'text');
    const members = this.store.members;
    const named = strings(b, 'judges') ?? [];
    const unknown = named.find((j) => !members.some((m) => m.identity === j));
    if (unknown !== undefined) return err(422, 'judges', 'A judge is not a member.', 'judges');
    if (denyTrip(this.store, text + '\n' + change) !== undefined) return err(422, 'deny', 'Your deny list refuses this text.', 'text');
    const ref = (id: string): Suggestion['author'] => {
      const m = members.find((x) => x.identity === id)!;
      return { identity: m.identity, name: m.name, agent_name: m.agent_name };
    };
    const me = this.self().identity;
    const judges = [me, ...named.filter((j) => j !== me)].filter((j, i, a) => a.indexOf(j) === i).map(ref);
    const running = !this.store.suggestions.some((x) => x.running);
    const s: Suggestion = {
      hash: nextHash(this.store),
      author: ref(me),
      created_at: new Date().toISOString(),
      change,
      text,
      prompt_id: 'sha256:' + createHash('sha256').update(text).digest('hex'),
      judges,
      status: SuggestionStatus.Judging,
      judge: true,
      running,
      rounds: [],
      live: false,
      can_withdraw: true,
      pull_request_owed: false
    };
    this.store.suggestions.push(s);
    return ok(s, 201);
  }

  private withdraw(hash: string): MockResponse {
    const s = this.store.suggestions.find((x) => x.hash === hash);
    if (s === undefined) return notFound();
    if (!s.can_withdraw) return err(422, 'not_withdrawable', 'Only its author may withdraw it, while it is judging.');
    s.status = SuggestionStatus.Withdrawn;
    s.can_withdraw = false;
    const wasRunning = s.running;
    s.running = false;
    // As the node does: the retract drops the body, its change line with it.
    s.text = '';
    s.change = '';
    if (wasRunning) {
      const next = this.store.suggestions.find((x) => x.status === SuggestionStatus.Judging && x.judge);
      if (next !== undefined) next.running = true;
    }
    return { status: 204 };
  }

  private pairNote(n: MockNote): MockResponse {
    const running = this.store.suggestions.find((x) => x.running);
    const first = n.versions[0];
    if (running === undefined || first === undefined || n.versions.length !== 1) return err(422, 'not_pairable', 'Nothing to pair.');
    const second = { ...first, id: n.id + '-v2', number: 2, text: (first.text ?? '') + '\nStuck on: one line, as suggested.' };
    // As the node does: the two versions in a random order, neither saying which prompt wrote it.
    if (Math.random() < 0.5) n.versions = [first, second];
    else
      n.versions = [
        { ...second, number: 1 },
        { ...first, number: 2 }
      ];
    n.pair = { suggestion: running.hash, suggested: second.id };
    return { status: 204 };
  }

  private noteTime(): { time: string; time_zone: string } {
    return { time: this.store.noteTime, time_zone: 'America/New_York' };
  }

  private status(): MockResponse {
    const s = this.store;
    const first = s.notes.find((n) => n.id === s.firstNote && n.shared_at === undefined);
    const me = this.self();
    return ok({
      member_name: me.name,
      agent_name: me.agent_name,
      first_run: s.firstRun,
      ...(first === undefined ? {} : { first_note: { id: first.id, written_at: first.written_at } }),
      open_asks: this.allAsks().filter((x) => x.status === 'open').length,
      notes_awaiting_approval: s.notes.filter((n) => n.status === NoteStatus.Waiting && n.progress === undefined).length,
      stage: me.stage,
      ...(this.warning() === undefined ? {} : { pause_warning: this.warning() }),
      // relay-1 mails, as in the demo node (node/web/demo.ml)
      phone_app_url: 'https://relay-1.example/app/'
    });
  }

  // node/web/store.ml Pause: the oldest waiting note's 30 days, from when it was written or the last
  // Unpause, whichever is later.
  private pauseAt(): { note: MockNote; from: number; at: number } | undefined {
    const unpaused = this.store.unpausedAt === undefined ? 0 : Date.parse(this.store.unpausedAt);
    return this.store.notes
      .filter((n) => n.status === NoteStatus.Waiting)
      .map((note) => {
        const from = Math.max(Date.parse(note.written_at), unpaused);
        return { note, from, at: from + 30 * DAY };
      })
      .sort((a, b) => a.at - b.at)[0];
  }

  private warning(): PauseWarning | undefined {
    const next = this.pauseAt();
    const now = Date.now();
    if (this.self().stage !== Stage.Active || next === undefined || now < next.at - 3 * DAY) return undefined;
    return {
      note: { id: next.note.id, written_at: next.note.written_at },
      waited_days: Math.floor((now - next.from) / DAY),
      pauses_at: new Date(next.at).toISOString()
    };
  }

  private pauseIfDue(): MockResponse | undefined {
    const next = this.pauseAt();
    return next !== undefined && Date.now() >= next.at && this.self().stage === Stage.Active
      ? this.pause(PauseReason.NoteWaited)
      : undefined;
  }

  private paused(): Paused | undefined {
    const p = this.store.pause;
    if (p === undefined) return undefined;
    const waiting = [...this.store.notes]
      .filter((n) => n.status === NoteStatus.Waiting)
      .sort((a, b) => a.written_at.localeCompare(b.written_at))[0];
    return {
      since: p.since,
      reason: p.reason,
      note_time: '07:00',
      ...(waiting === undefined ? {} : { waiting_note: { id: waiting.id, written_at: waiting.written_at } })
    };
  }

  /** Pause, from Active only: the Paused status note goes out at once. */
  private pause(reason: PauseReason): MockResponse {
    const me = this.self();
    if (me.stage !== Stage.Active) return err(422, 'not_active', 'Only an Active member pauses: your first note has not gone out yet.');
    const since = new Date().toISOString();
    me.stage = Stage.Paused;
    me.last_note_at = since;
    me.last_status_note = StatusNote.Paused;
    this.store.pause = { since, reason };
    this.store.messages.push({
      hash: nextHash(this.store),
      kind: 'summary',
      voice: Voice.Agent,
      author: { identity: me.identity, name: me.name, agent_name: me.agent_name },
      created_at: since,
      status: MessageStatus.Posted,
      status_note: StatusNote.Paused,
      replies: []
    });
    return ok(this.paused(), 201);
  }

  private post(body: unknown): MockResponse {
    const s = this.store;
    const text = (str(body, 'text') ?? '').trim();
    if (text === '') return err(422, 'empty', 'Write something first.', 'text');
    const replyTo = str(body, 'reply_to');
    const parent = replyTo === undefined ? undefined : s.messages.find((x) => x.hash === replyTo);
    if (replyTo !== undefined && parent === undefined) return err(422, 'unknown_reply_to', 'That message is gone.', 'reply_to');
    const me = this.self();
    if (me.stage !== Stage.Active) return err(422, 'not_active', 'Nothing is posted in your name until your first note goes out.');
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
    return ok(m, 201);
  }

  /** The New repositories local ask, held while any repository is undecided, as the node holds it
   * (node/web/store.ml, Repositories.hold_ask); it leads the open asks and takes no answer here. */
  private localAsks(): Ask[] {
    const undecided = this.repositories.repositories.filter((r) => r.status === RepositoryStatus.Undecided);
    if (undecided.length === 0) return [];
    const n = undecided.length;
    const found = undecided.map((r) => r.found_at).sort()[0] ?? new Date().toISOString();
    return [
      {
        id: 'repositories',
        kind: AskKind.Repositories,
        local: true,
        title: 'New repositories',
        status: AskStatus.Open,
        created_at: found,
        detail:
          n === 1
            ? '1 repository on this machine waits for you to decide whether Digestif reads it. Until you decide, it is not read.'
            : String(n) +
              ' repositories on this machine wait for you to decide whether Digestif reads them. Until you decide, they are not read.',
        options: [],
        on_no_answer: 'Nothing is read until you decide, and the ask stays open.'
      }
    ];
  }

  private allAsks(): Ask[] {
    return [...this.localAsks(), ...this.store.asks];
  }

  private asks(q: URLSearchParams): MockResponse {
    const status = q.get('status') as AskStatus | null;
    const rank = (x: { status: string; local?: boolean }): number => (x.status === 'open' ? (x.local === true ? 0 : 1) : 2);
    return page(
      this.allAsks()
        .filter((x) => status === null || x.status === status)
        .sort((x, y) => rank(x) - rank(y) || y.created_at.localeCompare(x.created_at))
        .map(({ detail: _d, options: _o, on_no_answer: _n, message: _m, answer: _a, local: _l, ...rest }) => rest),
      q,
      (x) => x.id
    );
  }

  private answer(x: Ask, body: unknown): MockResponse {
    if (x.local) return err(422, 'local', 'This ask is answered on its own page, and closes itself once nothing waits.');
    const optionId = str(body, 'option_id');
    if (x.status !== 'open') return err(422, 'not_open', 'This ask is no longer open.');
    if (optionId === undefined || !x.options.some((o) => o.id === optionId))
      return err(422, 'unknown_option', 'No such option.', 'option_id');
    x.status = AskStatus.Answered;
    x.answer = { option_id: optionId, answered_at: new Date().toISOString() };
    return ok(x, 201);
  }

  /** The node checks the code's own check and that the phrase is this member's; the mock checks the
   * code exactly and the phrase by its word count, and admits the phone's key as a device. */
  private addPhone(body: unknown): MockResponse {
    const code = (str(body, 'pairing_code') ?? '').replace(/\s+/g, '');
    const phrase = (str(body, 'recovery_phrase') ?? '')
      .trim()
      .split(/\s+/)
      .filter((w) => w !== '');
    const parts = code.split('.');
    const keys = parts[1] === undefined ? Buffer.alloc(0) : Buffer.from(parts[1], 'base64url');
    if (parts.length !== 3 || parts[0] !== 'p1' || keys.length !== 64)
      return err(422, 'invalid', 'Not a pairing code: it starts with p1. and comes from the phone.', 'pairing_code');
    if (createHash('sha256').update(keys).digest().subarray(0, 3).toString('base64url') !== parts[2])
      return err(422, 'invalid', "The pairing code's check does not match; retype it.", 'pairing_code');
    if (phrase.length !== 24)
      return err(422, 'invalid', 'A recovery phrase has 24 words, not ' + String(phrase.length) + '.', 'recovery_phrase');
    const me = this.store.members.find((m) => m.identity === this.store.self);
    if (me === undefined) return notFound();
    const device = {
      key: 'ed25519:' + keys.subarray(0, 32).toString('base64url'),
      role: 'device',
      admitted_at: new Date().toISOString(),
      phone: true
    };
    me.devices.push(device);
    return ok(device, 201);
  }

  /** The node checks the phrase is this member's; the mock checks its word count. */
  private revokePhone(key: string, body: unknown): MockResponse {
    const me = this.self();
    const phone = me.devices.find((d) => d.key === key && d.phone === true);
    if (phone === undefined) return notFound();
    if (phone.revoked_at !== undefined) return err(422, 'revoked', 'This phone is already removed.');
    const words = (str(body, 'recovery_phrase') ?? '')
      .trim()
      .split(/\s+/)
      .filter((w) => w !== '');
    if (words.length !== 24)
      return err(422, 'invalid', 'A recovery phrase has 24 words, not ' + String(words.length) + '.', 'recovery_phrase');
    phone.revoked_at = new Date().toISOString();
    return ok(phone);
  }

  /** A new card: both names, trimmed. */
  private saveNames(body: unknown): MockResponse {
    const name = (str(body, 'member_name') ?? '').trim();
    const agentName = (str(body, 'agent_name') ?? '').trim();
    if (name === '') return err(422, 'invalid', 'Enter your name.', 'member_name');
    if (agentName === '') return err(422, 'invalid', 'Name your agent.', 'agent_name');
    const me = this.self();
    me.name = name;
    me.agent_name = agentName;
    return ok({ member_name: name, agent_name: agentName, published: true });
  }

  /** How long the mock's agent check runs: long enough to read Checking, short enough for a test. */
  static readonly AGENT_CHECK_MS = 2000;

  /**
   * The node starts the agent check in the background and answers at once; the mock passes claude and
   * codex, and fails a path naming signed-out, once AGENT_CHECK_MS has passed.
   */
  private saveAgent(body: unknown): MockResponse {
    const typed = (str(body, 'path') ?? '').trim();
    const base = typed.split('/').pop() ?? '';
    if (!typed.startsWith('/') || base === '') return err(422, 'not_a_program', typed + ' is not a program on this machine.', 'path');
    if (this.agentCheck()?.status === AgentCheckStatus.Checking) return err(422, 'checking', 'A check is still running.');
    const name = base === 'claude' ? 'Claude Code' : base === 'codex' ? 'Codex' : base;
    const message = typed.includes('signed-out') ? name + ' does not answer (exit 1): not signed in. Not saved.' : undefined;
    this.store.agentCheck = { name, path: typed, endsAt: Date.now() + MockNode.AGENT_CHECK_MS, message };
    return ok(this.agentCheck(), 202);
  }

  /** The check's state now, saving the agent the first time it is read past a pass. */
  private agentCheck(): AgentCheck | undefined {
    const k = this.store.agentCheck;
    if (k === undefined) return undefined;
    const base = { name: k.name, path: k.path };
    if (Date.now() < k.endsAt) return { ...base, status: AgentCheckStatus.Checking };
    if (k.message !== undefined) return { ...base, status: AgentCheckStatus.Failed, message: k.message };
    if (this.store.agent?.path !== k.path) this.store.agent = base;
    return { ...base, status: AgentCheckStatus.Passed };
  }

  private saveBrief(body: unknown): MockResponse {
    const text = (str(body, 'text') ?? '').trim();
    if (text === '') return err(422, 'empty', 'Write a few lines about yourself.', 'text');
    this.store.brief = { text, updated_at: new Date().toISOString() };
    return ok({ ...this.store.brief, can_draft: true });
  }

  // The mock node has a writer: a draft built from the card's name and the chosen sources.
  private draftBrief(): MockResponse {
    const chosen = this.store.sources.filter((x) => x.selected).map((x) => x.label.toLowerCase());
    const text =
      "I'm Ada Park. I build developer tools" +
      (chosen.length === 0 ? '.' : ', and lately my ' + chosen.join(' and ') + ' show a retry queue for the importer.');
    return ok({ text });
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

  // node/web/api.ml add_source: a label no other source has, a program by its absolute path.
  private addSource(body: unknown): MockResponse {
    const label = (str(body, 'label') ?? '').trim();
    const command = (strings(body, 'command') ?? []).map((a) => a.trim()).filter((a) => a !== '');
    const slug = label
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-|-$/g, '');
    const id = 'command-' + (slug === '' ? 'source' : slug);
    if (label === '') return err(422, 'empty', 'Name the source.', 'label');
    if (this.store.sources.some((x) => x.id === id || x.label.toLowerCase() === label.toLowerCase())) {
      return err(422, 'taken', 'Another source has that name.', 'label');
    }
    const program = command[0];
    if (program === undefined) return err(422, 'program', 'Name the program.', 'command');
    if (!program.startsWith('/') && !program.startsWith('~'))
      return err(422, 'program', 'Name the program by its absolute path.', 'command');
    this.store.sources = [
      ...this.store.sources,
      { id, kind: SourceKind.Command, label, paths: command, yields: ['Lines the program prints for the last day'], selected: false }
    ];
    return ok(this.store.sources, 201);
  }

  private removeSource(id: string): MockResponse {
    const source = this.store.sources.find((x) => x.id === id);
    if (source === undefined) return err(404, 'not_found', 'Not found.');
    if (source.kind !== SourceKind.Command) return err(422, 'discovered', 'This machine offers that source; leave it unselected instead.');
    this.store.sources = this.store.sources.filter((x) => x.id !== id);
    return ok(this.store.sources);
  }

  // The Playwright suite's way to walk the first note: { progress } is its row before the run hands
  // it over (node/web/store.ml Notes.start), { note } the waiting note the hand-over filled. Never
  // part of the build.
  private setFirstNote(body: unknown): MockResponse {
    const s = this.store;
    const handed = str(body, 'note');
    s.notes = s.notes.filter((n) => n.progress === undefined);
    // Setup is done once the chat has started the first note (node/web/store.ml Setup.finished), so
    // the navigation is open from then on.
    if (handed !== undefined) {
      s.firstNote = handed;
      s.firstRun = false;
      return ok({ id: handed });
    }
    const progress = (body as { progress: NoteProgress }).progress;
    s.notes.push({ id: 'first', written_at: new Date().toISOString(), status: NoteStatus.Waiting, versions: [], progress });
    s.firstNote = 'first';
    s.firstRun = false;
    return ok({ id: 'first' });
  }

  // node/web/api.ml Notes. An edit's checks stay running in the mock, as on a node with no check hook.
  private notes(q: URLSearchParams): MockResponse {
    const s = this.store;
    const rows: NoteSummary[] = s.notes
      .filter((n) => n.progress === undefined)
      .sort((x, y) => y.written_at.localeCompare(x.written_at))
      .map((n) => {
        const text = shown(n)?.text;
        return {
          id: n.id,
          written_at: n.written_at,
          status: n.status,
          ...(n.shared_at === undefined ? {} : { shared_at: n.shared_at }),
          ...(text === undefined ? {} : { preview: previewLine(text) })
        };
      });
    const noActivity = s.notes.some((n) => n.progress?.state === NoteProgressState.NoActivity);
    const notes = page(rows, q, (n) => n.id);
    if (notes.status !== 200) return notes;
    return ok({
      notes: notes.body as NoteSummary[],
      suggest_auto_approval: s.approval === 'every_note_waits' && s.unchanged >= 5,
      no_activity: noActivity
    });
  }

  private note(n: MockNote, versionId?: string): MockResponse {
    if (n.progress !== undefined && versionId === undefined) {
      const body: Note = {
        id: n.id,
        written_at: n.written_at,
        status: n.status,
        progress: n.progress,
        can_approve: false,
        can_edit: false
      };
      return ok(body);
    }
    const v = versionId === undefined ? shown(n) : n.versions.find((x) => x.id === versionId);
    if (v === undefined) return err(404, 'not_found', 'Not found.');
    const newest = n.versions[n.versions.length - 1];
    const waiting = n.status === NoteStatus.Waiting;
    const { learned: _l, ...version } = v;
    const pair = waiting && n.pair !== undefined && n.versions.length === 2 ? n.versions.map(({ learned: _x, ...p }) => p) : undefined;
    const body: Note = {
      id: n.id,
      written_at: n.written_at,
      status: n.status,
      ...(n.shared_at === undefined ? {} : { shared_at: n.shared_at }),
      version,
      ...(newest !== undefined && newest.number > v.number ? { newer_version_id: newest.id } : {}),
      ...(pair === undefined ? {} : { pair }),
      can_approve: waiting && (pair !== undefined || v === newest) && v.text !== undefined && v.text !== '',
      can_edit: waiting,
      ...(n.not_sent === undefined ? {} : { not_sent: n.not_sent })
    };
    return ok(body);
  }

  // node/web/api.ml Notes.message_of: a note not yet signed is a message of its own, at its id.
  // The mock signs at once on approval, so an approved note reads as posted.
  private noteMessage(n: MockNote): Message {
    const me = this.self();
    const v = shown(n);
    const status =
      n.status === NoteStatus.Waiting
        ? MessageStatus.AwaitingApproval
        : n.status === NoteStatus.Dismissed
          ? MessageStatus.Dismissed
          : n.shared_at === undefined
            ? MessageStatus.Sending
            : MessageStatus.Posted;
    return {
      hash: n.id,
      kind: 'summary',
      voice: n.versions[n.versions.length - 1]?.voice ?? Voice.Agent,
      author: { identity: me.identity, name: me.name, agent_name: me.agent_name },
      created_at: n.written_at,
      status,
      ...(v?.text === undefined ? {} : { text: v.text }),
      note_id: n.id,
      replies: []
    };
  }

  /** The notes the feed shows as messages of their own: waiting for the member, written. */
  private notesInFeed(): MockMessage[] {
    return this.store.notes
      .filter((n) => n.status === NoteStatus.Waiting && n.progress === undefined && n.versions.length > 0)
      .map((n) => this.noteMessage(n));
  }

  private dismiss(n: MockNote): MockResponse {
    if (n.status !== NoteStatus.Waiting || n.progress !== undefined) return err(422, 'not_waiting', 'This note is not waiting.');
    n.status = NoteStatus.Dismissed;
    n.dismissed_at = new Date().toISOString();
    return this.note(n);
  }

  private noteLog(n: MockNote): unknown[] {
    const log: unknown[] = [{ at: n.written_at, event: 'written', version_id: n.versions[0]?.id }];
    for (const v of n.versions.slice(1)) log.push({ at: v.created_at, event: 'edited', version_id: v.id });
    if (n.status === NoteStatus.Approved) log.push({ at: n.written_at, event: 'approved', version_id: n.approved_version });
    if (n.shared_at !== undefined) log.push({ at: n.shared_at, event: 'shared' });
    if (n.dismissed_at !== undefined) log.push({ at: n.dismissed_at, event: 'dismissed' });
    return log;
  }

  private edit(n: MockNote, body: unknown): MockResponse {
    if (n.status !== NoteStatus.Waiting) return err(422, 'not_waiting', 'This note was already approved.');
    const text = (str(body, 'text') ?? '').trim();
    if (text === '') return err(422, 'empty', 'Write the note first.', 'text');
    const edited = str(body, 'edited_version_id');
    if (!n.versions.some((v) => v.id === edited)) return err(422, 'edited_version_id', 'That version is gone.', 'edited_version_id');
    const number = n.versions.length + 1;
    const running = { pii: CheckState.Running, rules: CheckState.Running };
    const v = {
      id: n.id + '-v' + String(number),
      number,
      voice: Voice.Person,
      created_at: new Date().toISOString(),
      checks: running,
      removed: false,
      learned: false
    };
    n.versions.push(v);
    delete n.not_sent;
    this.store.unchanged = 0;
    return { ...this.note(n, edited), status: 201 };
  }

  private approve(n: MockNote, body: unknown): MockResponse {
    const paired = n.pair !== undefined && n.versions.length === 2 ? n.versions.find((x) => x.id === str(body, 'version_id')) : undefined;
    const v = paired ?? n.versions[n.versions.length - 1];
    if (n.status !== NoteStatus.Waiting || v === undefined || v.text === undefined || v.text === '')
      return err(422, 'not_approvable', 'There is nothing to approve.');
    if (str(body, 'version_id') !== v.id) return err(422, 'version_id', 'A newer version is on the page.', 'version_id');
    n.status = NoteStatus.Approved;
    n.approved_version = v.id;
    if (paired !== undefined) this.pick(n, v.id);
    // The mock signs at once: the app's send job runs on the node's next pass.
    n.shared_at = new Date().toISOString();
    this.store.unchanged = n.versions.length > 1 ? 0 : this.store.unchanged + 1;
    // The first approved note going out ends Onboarding; any note going out is the last note.
    const me = this.self();
    if (me.stage === Stage.Onboarding) me.stage = Stage.Active;
    me.last_note_at = n.shared_at;
    delete me.last_status_note;
    return this.note(n);
  }

  /** The pick a pair's approval makes; the mock decides a round on this member's pick alone. */
  private pick(n: MockNote, approved: string): void {
    const s = this.store.suggestions.find((x) => x.hash === n.pair?.suggestion);
    if (s === undefined) return;
    const me = this.self();
    const pick = approved === n.pair?.suggested ? PromptPick.Suggested : PromptPick.Current;
    const open = s.rounds.find((r) => r.result === undefined && !r.picks.some((p) => p.judge.identity === me.identity));
    const round: Suggestion['rounds'][number] = open ?? { number: s.rounds.length + 1, picks: [] };
    if (open === undefined) s.rounds.push(round);
    round.picks.push({ judge: { identity: me.identity, name: me.name, agent_name: me.agent_name }, pick, at: new Date().toISOString() });
    if (round.picks.length < s.judges.length) return;
    const all = (p: PromptPick): boolean => round.picks.every((x) => x.pick === p);
    round.result = all(PromptPick.Suggested) ? RoundResult.Adopted : all(PromptPick.Current) ? RoundResult.NotAdopted : RoundResult.Split;
    if (round.result === RoundResult.Split) return;
    s.status = round.result === RoundResult.Adopted ? SuggestionStatus.Adopted : SuggestionStatus.NotAdopted;
    s.decided_at = new Date().toISOString();
    s.running = false;
    s.can_withdraw = false;
    if (s.status === SuggestionStatus.Adopted) {
      for (const x of this.store.suggestions) x.live = false;
      s.live = true;
      s.pull_request_owed = s.author.identity === me.identity;
      this.store.livePrompt = { text: s.text, adoption: { suggestion: s.hash, change: s.change, author: s.author, at: s.decided_at } };
    }
  }

  private quietHours(): QuietHours | undefined {
    const q = this.store.quietHours;
    if (q === undefined) return undefined;
    const minute = (t: string): number => Number(t.slice(0, 2)) * 60 + Number(t.slice(3, 5));
    const d = new Date();
    const m = d.getHours() * 60 + d.getMinutes();
    const [a, b] = [minute(q.start), minute(q.end)];
    const active = a < b ? m >= a && m < b : m >= a || m < b;
    if (!active) return { ...q, active };
    const ends = new Date(d);
    ends.setHours(Math.floor(b / 60), b % 60, 0, 0);
    if (ends <= d) ends.setDate(ends.getDate() + 1);
    return { ...q, active, ends_at: ends.toISOString() };
  }

  private saveQuietHours(body: unknown): MockResponse {
    const time = /^([01][0-9]|2[0-3]):[0-5][0-9]$/;
    const start = str(body, 'start') ?? '';
    const end = str(body, 'end') ?? '';
    if (!time.test(start)) return err(422, 'time', 'Start is a time like 22:00.', 'start');
    if (!time.test(end)) return err(422, 'time', 'End is a time like 07:00.', 'end');
    if (start === end) return err(422, 'empty', 'Start and end are the same.', 'end');
    this.store.quietHours = { start, end };
    return ok(this.quietHours());
  }

  private rules(): unknown {
    const s = this.store;
    const quiet = this.quietHours();
    return {
      text: s.rulesText,
      ...(s.rulesUpdatedAt === undefined ? {} : { updated_at: s.rulesUpdatedAt }),
      ...(quiet === undefined ? {} : { quiet_hours: quiet }),
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
