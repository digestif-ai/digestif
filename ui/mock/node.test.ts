import { createHash } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import type { ApprovalQueue, Device, Member, Message, NodeError, NodeStatus, Source } from '#generated/com-bryzek-digestif-node.ts';
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

  it('writes a note now only once a source is chosen', () => {
    const node = new MockNode();
    expect(node.handle('POST', '/api/v0/approvals/run').status).toBe(422);
    node.handle('PUT', '/api/v0/sources', { selected: ['git'] });
    expect(node.handle('POST', '/api/v0/approvals/run').status).toBe(204);
  });

  it('counts approvals toward five', () => {
    const node = new MockNode();
    const queue = body<ApprovalQueue>(node, 'GET', 'approvals');
    const waiting = queue.notes.find((n) => n.status === 'awaiting_approval');
    expect(waiting).toBeDefined();
    node.handle('POST', '/api/v0/approvals/' + encodeURIComponent(waiting?.hash ?? '') + '/approve');
    expect(body<ApprovalQueue>(node, 'GET', 'approvals').approved).toBe(queue.approved + 1);
    expect(node.handle('POST', '/api/v0/approvals/' + encodeURIComponent(waiting?.hash ?? '') + '/approve').status).toBe(422);
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
});
