// An in-memory node answering spec/digestif-node.json, for `npm run dev` without a node and for the
// tests. It implements the contract's rules (deny layer trips, notes and their approval, mute) loosely
// enough to drive every screen, and is never part of the build.
import { createHash } from 'node:crypto';
import {
  ApprovalSetting,
  type Ask,
  AskStatus,
  type DenyEntryKind,
  type FeedItem,
  type FirstNote,
  FirstNoteState,
  type Member,
  type MemberSummary,
  type Note,
  NoteStatus,
  type NoteSummary,
  CheckState,
  type Paused,
  PauseReason,
  type PauseWarning,
  type Message,
  MessageStatus,
  type NodeError,
  type QuietHours,
  SourceKind,
  StatusNote,
  Stage,
  Voice
} from '#generated/com-bryzek-digestif-node.ts';
import { seed, type MockMessage, type MockNote, type Store } from './fixtures.ts';

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

const SECRET = /(sk-[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|[a-z]+:\/\/[^\s:]+:[^\s@]+@)/;

function item(m: MockMessage): FeedItem {
  const preview = (m.text ?? (m.status === 'refused' ? 'Refused before signing' : 'Sealed')).split('\n')[0] ?? '';
  return {
    hash: m.hash,
    kind: m.kind,
    voice: m.voice,
    author: m.author,
    ...(m.recipient === undefined ? {} : { recipient: m.recipient }),
    created_at: m.created_at,
    status: m.status,
    preview: preview.slice(0, 140),
    ...(m.status_note === undefined ? {} : { status_note: m.status_note })
  };
}

/** Members: Active first, then Paused, then Onboarding, the newest note first within each. */
const STAGE_RANK: Record<string, number> = { active: 0, paused: 1, onboarding: 2 };

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

/** The newest version whose checks passed: what a note page shows by default. */
function shown(n: MockNote): MockNote['versions'][number] | undefined {
  return [...n.versions].reverse().find((v) => v.checks.pii === CheckState.Passed && v.checks.rules === CheckState.Passed);
}

function withFound<T>(value: T | undefined, run: (v: T) => MockResponse): MockResponse {
  return value === undefined ? notFound() : run(value);
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
            s.members
              .filter((m) => m.status !== 'revoked')
              .sort(
                (x, y) =>
                  (STAGE_RANK[x.stage] ?? 2) - (STAGE_RANK[y.stage] ?? 2) || (y.last_note_at ?? '').localeCompare(x.last_note_at ?? '')
              )
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
      ['POST', 'phones', (_p, b) => this.addPhone(b)],
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
      ['GET', 'rules/deny', () => ok(s.deny)],
      ['POST', 'rules/deny', (_p, b) => this.addDeny(b)],
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
      ['GET', 'notes', () => this.notes()],
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
      ]
    ];
  }

  private noteTime(): { time: string; time_zone: string } {
    return { time: this.store.noteTime, time_zone: 'America/New_York' };
  }

  private status(): MockResponse {
    const s = this.store;
    const me = this.self();
    return ok({
      member_name: me.name,
      agent_name: me.agent_name,
      first_run: s.firstRun,
      ...(s.firstNote === undefined ? {} : { first_note: s.firstNote }),
      open_asks: s.asks.filter((x) => x.status === 'open').length,
      notes_awaiting_approval: s.notes.filter((n) => n.status === NoteStatus.Waiting).length,
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
    const device = { key: 'ed25519:' + keys.subarray(0, 32).toString('base64url'), role: 'device', admitted_at: new Date().toISOString() };
    me.devices.push(device);
    return ok(device, 201);
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

  // The Playwright suite's way to walk the first note's states. Never part of the build.
  private setFirstNote(body: unknown): MockResponse {
    const note = body as FirstNote;
    this.store.firstNote = note;
    this.store.firstRun = note.state !== FirstNoteState.NoActivity;
    return ok(note);
  }

  // node/web/api.ml Notes. An edit's checks stay running in the mock, as on a node with no check hook.
  private notes(): MockResponse {
    const s = this.store;
    const rows: NoteSummary[] = [...s.notes]
      .sort((x, y) => y.written_at.localeCompare(x.written_at))
      .map((n) => {
        const text = shown(n)?.text;
        return {
          id: n.id,
          written_at: n.written_at,
          status: n.status,
          ...(n.shared_at === undefined ? {} : { shared_at: n.shared_at }),
          ...(text === undefined ? {} : { preview: (text.split('\n')[0] ?? '').slice(0, 140) })
        };
      });
    return ok({ notes: rows, suggest_auto_approval: s.approval === 'every_note_waits' && s.unchanged >= 3, no_activity: false });
  }

  private note(n: MockNote, versionId?: string): MockResponse {
    const v = versionId === undefined ? shown(n) : n.versions.find((x) => x.id === versionId);
    if (v === undefined) return err(404, 'not_found', 'Not found.');
    const newest = n.versions[n.versions.length - 1];
    const waiting = n.status === NoteStatus.Waiting;
    const { learned: _l, ...version } = v;
    const body: Note = {
      id: n.id,
      written_at: n.written_at,
      status: n.status,
      ...(n.shared_at === undefined ? {} : { shared_at: n.shared_at }),
      version,
      ...(newest !== undefined && newest.number > v.number ? { newer_version_id: newest.id } : {}),
      can_approve: waiting && v === newest && v.text !== undefined && v.text !== '',
      can_edit: waiting,
      ...(n.not_sent === undefined ? {} : { not_sent: n.not_sent })
    };
    return ok(body);
  }

  private noteLog(n: MockNote): unknown[] {
    const log: unknown[] = [{ at: n.written_at, event: 'written', version_id: n.versions[0]?.id }];
    for (const v of n.versions.slice(1)) log.push({ at: v.created_at, event: 'edited', version_id: v.id });
    if (n.status === NoteStatus.Approved) log.push({ at: n.written_at, event: 'approved', version_id: n.approved_version });
    if (n.shared_at !== undefined) log.push({ at: n.shared_at, event: 'shared' });
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
    const v = n.versions[n.versions.length - 1];
    if (n.status !== NoteStatus.Waiting || v === undefined || v.text === undefined || v.text === '')
      return err(422, 'not_approvable', 'There is nothing to approve.');
    if (str(body, 'version_id') !== v.id) return err(422, 'version_id', 'A newer version is on the page.', 'version_id');
    n.status = NoteStatus.Approved;
    n.approved_version = v.id;
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
