import { createHash } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import type {
  Device,
  Member,
  Message,
  NodeError,
  NodeStatus,
  Note,
  NotePrompt,
  Notes,
  Source,
  Suggestion,
  SuggestionSummary
} from '#generated/com-bryzek-digestif-node.ts';
import { MockNode } from './node.ts';

const body = <T>(node: MockNode, method: string, path: string, payload?: unknown): T =>
  node.handle(method, '/api/v0/' + path, payload).body as T;

describe('mock node', () => {
  it('starts on first run with nothing selected', () => {
    const node = new MockNode();
    expect(body<NodeStatus>(node, 'GET', 'status').first_run).toBe(true);
    expect(body<Source[]>(node, 'GET', 'sources').every((s) => !s.selected)).toBe(true);
  });

  it('the mock leaves first run when its sources are saved', () => {
    const node = new MockNode();
    expect(node.handle('PUT', '/api/v0/sources', { selected: [] }).status).toBe(200);
    expect(body<NodeStatus>(node, 'GET', 'status').first_run).toBe(false);
  });

  it('adds a command source, refuses a relative program and a taken name, and removes only command sources', () => {
    const node = new MockNode();
    const add = (label: string, command: string[]) => node.handle('POST', '/api/v0/sources', { label, command });
    expect(add('Athena', ['athena']).status).toBe(422);
    expect(add('Athena', ['/usr/local/bin/athena', 'activity']).status).toBe(201);
    expect(add('athena', ['/bin/echo']).status).toBe(422);
    expect(body<Source[]>(node, 'GET', 'sources').find((s) => s.id === 'command-athena')?.selected).toBe(false);
    expect(node.handle('DELETE', '/api/v0/sources/git').status).toBe(422);
    expect(node.handle('DELETE', '/api/v0/sources/command-athena').status).toBe(200);
    expect(node.handle('DELETE', '/api/v0/sources/command-athena').status).toBe(404);
  });

  it('refuses a post the deny layer trips, naming the rule and not the text', () => {
    const node = new MockNode();
    const out = node.handle('POST', '/api/v0/messages', { text: 'see internal.example.com/x' });
    const m = out.body as Message;
    expect(out.status).toBe(201);
    expect(m.status).toBe('refused');
    expect(m.refused_rule).toBe('deny: domain');
    expect(m.text).toBeUndefined();
  });

  it('refuses a secret shape with no deny entry', () => {
    const node = new MockNode();
    const m = body<Message>(node, 'POST', 'messages', { text: 'key AKIAABCDEFGHIJKLMNOP' });
    expect(m.refused_rule).toBe('detector: secret shape');
  });

  it('pages notes, asks, members and the deny list by cursor, as the node does (ISS-41988)', () => {
    const node = new MockNode();
    const ids = (path: string, idOf: (row: Record<string, string>) => string, key?: string): string[] => {
      const answered = body<unknown>(node, 'GET', path);
      const rows = (key === undefined ? answered : (answered as Record<string, unknown>)[key]) as Record<string, string>[];
      return rows.map(idOf);
    };
    const lists: [string, (row: Record<string, string>) => string, string | undefined][] = [
      ['notes', (r) => r['id'] ?? '', 'notes'],
      ['asks', (r) => r['id'] ?? '', undefined],
      ['members', (r) => r['identity'] ?? '', undefined],
      ['rules/deny', (r) => r['id'] ?? '', undefined]
    ];
    for (const [path, idOf, key] of lists) {
      const full = ids(path, idOf, key);
      const walked: string[] = [];
      for (;;) {
        const cursor = walked.length === 0 ? '' : '&cursor=' + encodeURIComponent(walked[walked.length - 1] ?? '');
        const page = ids(path + '?limit=1' + cursor, idOf, key);
        if (page.length === 0) break;
        walked.push(...page);
      }
      expect(walked).toEqual(full);
      expect(node.handle('GET', '/api/v0/' + path + '?cursor=nope').status).toBe(422);
      expect(node.handle('GET', '/api/v0/' + path + '?limit=0').status).toBe(422);
    }
  });

  it('approves a waiting note and suggests auto approval after five unchanged', () => {
    const node = new MockNode();
    expect(body<Notes>(node, 'GET', 'notes').suggest_auto_approval).toBe(false);
    const n = body<Note>(node, 'GET', 'notes/n3');
    expect(n.can_approve).toBe(true);
    expect(node.handle('POST', '/api/v0/notes/n3/approve', { version_id: n.version?.id }).status).toBe(200);
    expect(body<Notes>(node, 'GET', 'notes').suggest_auto_approval).toBe(true);
    expect(node.handle('POST', '/api/v0/notes/n3/approve', { version_id: n.version?.id }).status).toBe(422);
    expect(node.handle('POST', '/api/v0/notes/suggestion/dismiss').status).toBe(204);
    expect(body<Notes>(node, 'GET', 'notes').suggest_auto_approval).toBe(false);
  });

  it('an edit makes a newer version whose checks run, and the page keeps the one being read', () => {
    const node = new MockNode();
    const n = body<Note>(node, 'GET', 'notes/n3');
    const out = node.handle('POST', '/api/v0/notes/n3/versions', {
      text: 'Worked on: the UI.',
      edited_version_id: n.version?.id,
      approve: false
    });
    expect(out.status).toBe(201);
    const after = out.body as Note;
    expect(after.version?.number).toBe(1);
    expect(after.newer_version_id).toBe('n3-v2');
    expect(after.can_approve).toBe(false);
    const v2 = body<Note>(node, 'GET', 'notes/n3?version=n3-v2').version;
    expect(v2?.checks.pii).toBe('running');
    expect(v2?.text).toBeUndefined();
  });

  it('keeps quiet hours on the rules and clears them', () => {
    const node = new MockNode();
    expect(node.handle('GET', '/api/v0/rules/quiet_hours').status).toBe(404);
    expect(node.handle('PUT', '/api/v0/rules/quiet_hours', { start: '7pm', end: '07:00' }).status).toBe(422);
    expect(node.handle('PUT', '/api/v0/rules/quiet_hours', { start: '22:00', end: '07:00' }).status).toBe(200);
    expect(body<{ quiet_hours?: { start: string } }>(node, 'GET', 'rules').quiet_hours?.start).toBe('22:00');
    expect(node.handle('DELETE', '/api/v0/rules/quiet_hours').status).toBe(204);
    expect(node.handle('GET', '/api/v0/rules/quiet_hours').status).toBe(404);
  });

  it('will not let a member mute themselves', () => {
    const node = new MockNode();
    expect(node.handle('PUT', '/api/v0/members/' + encodeURIComponent(node.store.self) + '/mute', { muted: true }).status).toBe(422);
  });

  it('pairs a phone from a well-formed code and refuses a mistyped one', () => {
    const node = new MockNode();
    const keys = Buffer.alloc(64, 7);
    const code = 'p1.' + keys.toString('base64url') + '.' + createHash('sha256').update(keys).digest().subarray(0, 3).toString('base64url');
    const phrase = Array.from({ length: 24 }, () => 'abandon').join(' ');
    const bad = node.handle('POST', '/api/v0/phones', { pairing_code: code.slice(0, -1) + 'A', recovery_phrase: phrase });
    expect(bad.status).toBe(422);
    expect((bad.body as NodeError[])[0]?.field).toBe('pairing_code');
    const out = node.handle('POST', '/api/v0/phones', { pairing_code: code, recovery_phrase: phrase });
    expect(out.status).toBe(201);
    const device = out.body as Device;
    const me = body<Member[]>(node, 'GET', 'members').find((m) => m.is_self);
    expect(me).toBeDefined();
    const member = body<Member>(node, 'GET', 'members/' + encodeURIComponent(me?.identity ?? ''));
    expect(member.devices.map((d) => d.key)).toContain(device.key);
  });

  it('serves the note prompt and its suggestions, refuses a suggestion without the rules placeholder, and withdraws only a judging one of its own', () => {
    const node = new MockNode();
    const np = body<NotePrompt>(node, 'GET', 'note_prompt');
    expect(np.adoption?.author.name).toBe('Ben Ortiz');
    expect(np.running?.change).toBe('Keep Stuck on to one line');
    expect(body<SuggestionSummary[]>(node, 'GET', 'suggestions').map((r) => r.status)).toEqual(['judging', 'adopted']);
    expect(node.handle('POST', '/api/v0/suggestions', { text: 'No placeholder', change: 'x' }).status).toBe(422);
    expect(node.handle('POST', '/api/v0/suggestions', { text: np.text, change: 'x' }).status).toBe(422);
    const made = node.handle('POST', '/api/v0/suggestions', {
      text: 'Shorter. {{always_on_rules}}',
      change: 'Shorter',
      judges: [np.adoption!.author.identity]
    });
    expect(made.status).toBe(201);
    const s = made.body as Suggestion;
    expect(s.judges.map((j) => j.name)).toEqual(['Ada Park', 'Ben Ortiz']);
    expect(s.running).toBe(false);
    const path = (h: string): string => 'suggestions/' + encodeURIComponent(h);
    expect(node.handle('DELETE', '/api/v0/' + path(np.adoption!.suggestion)).status).toBe(422);
    expect(node.handle('DELETE', '/api/v0/' + path(np.running!.hash)).status).toBe(204);
    expect(body<NotePrompt>(node, 'GET', 'note_prompt').running?.hash).toBe(s.hash);
  });

  it('a note in two versions approves either one, and the pick is recorded on the suggestion', () => {
    const node = new MockNode();
    const running = body<NotePrompt>(node, 'GET', 'note_prompt').running!;
    expect(node.handle('POST', '/api/v0/_note_pair', { id: 'n3' }).status).toBe(204);
    const n = body<Note>(node, 'GET', 'notes/n3');
    expect(n.pair?.length).toBe(2);
    expect(n.can_approve).toBe(true);
    const first = n.pair![0]!;
    expect(node.handle('POST', '/api/v0/notes/n3/approve', { version_id: first.id }).status).toBe(200);
    const after = body<Suggestion>(node, 'GET', 'suggestions/' + encodeURIComponent(running.hash));
    expect(after.rounds[0]?.picks.length).toBe(2);
    expect(after.rounds[0]?.result).toBeDefined();
  });
});
