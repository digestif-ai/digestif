import { describe, expect, it } from 'vitest';
import type { ApprovalQueue, Message, NodeStatus, NotePreview, Source } from '#generated/com-bryzek-digestif-node.ts';
import { MockNode } from './node.ts';

const body = <T>(node: MockNode, method: string, path: string, payload?: unknown): T =>
  node.handle(method, '/api/v0/' + path, payload).body as T;

describe('mock node', () => {
  it('starts on first run with nothing selected', () => {
    const node = new MockNode();
    expect(body<NodeStatus>(node, 'GET', 'status').first_run).toBe(true);
    expect(body<Source[]>(node, 'GET', 'sources').every((s) => !s.selected)).toBe(true);
  });

  it('saving an empty selection ends first run', () => {
    const node = new MockNode();
    expect(node.handle('PUT', '/api/v0/sources', { selected: [] }).status).toBe(200);
    expect(body<NodeStatus>(node, 'GET', 'status').first_run).toBe(false);
  });

  it('previews nothing for no sources and a note for some', () => {
    const node = new MockNode();
    expect(body<NotePreview>(node, 'POST', 'sources/preview', { selected: [] })).toEqual({ extracted: [] });
    const p = body<NotePreview>(node, 'POST', 'sources/preview', { selected: ['git'] });
    expect(p.text).toContain('Worked on');
    expect(p.extracted.length).toBeGreaterThan(0);
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

  it('counts approvals toward five', () => {
    const node = new MockNode();
    const queue = body<ApprovalQueue>(node, 'GET', 'approvals');
    const waiting = queue.notes.find((n) => n.status === 'awaiting_approval');
    expect(waiting).toBeDefined();
    node.handle('POST', '/api/v0/approvals/' + encodeURIComponent(waiting?.hash ?? '') + '/approve');
    expect(body<ApprovalQueue>(node, 'GET', 'approvals').approved).toBe(queue.approved + 1);
    expect(node.handle('POST', '/api/v0/approvals/' + encodeURIComponent(waiting?.hash ?? '') + '/approve').status).toBe(422);
  });

  it('will not let a member mute themselves', () => {
    const node = new MockNode();
    expect(node.handle('PUT', '/api/v0/members/' + encodeURIComponent(node.store.self) + '/mute', { muted: true }).status).toBe(422);
  });
});
