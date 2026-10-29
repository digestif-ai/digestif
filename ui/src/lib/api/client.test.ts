import { describe, expect, it } from 'vitest';
import { MockNode } from '#mock/node.ts';
import { createClient, isApiError } from './client.ts';

/** A fetch answered by the mock node, recording every request it saw. */
function mockFetch(node: MockNode): { fetch: typeof fetch; seen: Request[] } {
  const seen: Request[] = [];
  const f = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const req = new Request(new URL(String(input), 'http://node.local'), init);
    seen.push(req);
    const text = await req.text();
    const out = node.handle(req.method, req.url, text === '' ? undefined : (JSON.parse(text) as unknown));
    return new Response(out.body === undefined ? null : JSON.stringify(out.body), { status: out.status });
  };
  return { fetch: f as typeof fetch, seen };
}

describe('client', () => {
  it('sends the Digestif-Local header on every request', async () => {
    const { fetch, seen } = mockFetch(new MockNode());
    await createClient(fetch).status();
    expect(seen[0]?.headers.get('Digestif-Local')).toBe('1');
  });

  it('encodes keys and hashes as one path segment', async () => {
    const node = new MockNode();
    const { fetch, seen } = mockFetch(node);
    const identity = node.store.members[1]?.identity ?? '';
    const response = await createClient(fetch).member(identity);
    expect(isApiError(response)).toBe(false);
    expect(new URL(seen[0]?.url ?? '').pathname).toBe('/api/v0/members/' + encodeURIComponent(identity));
  });

  it('answers errors rather than throwing', async () => {
    const { fetch } = mockFetch(new MockNode());
    const response = await createClient(fetch).message('sha256:nope');
    expect(response.status).toBe(404);
    expect(isApiError(response) && response.errors[0]?.code).toBe('not_found');
  });

  it('reports a node that is not running', async () => {
    const down = (async () => {
      throw new TypeError('fetch failed');
    }) as typeof fetch;
    const response = await createClient(down).status();
    expect(response.status).toBe(0);
    expect(isApiError(response) && response.errors[0]?.code).toBe('unreachable');
  });

  it('answers 204 with no body', async () => {
    const { fetch } = mockFetch(new MockNode());
    const response = await createClient(fetch).removeDeny('deny-1');
    expect(response).toEqual({ data: undefined, status: 204 });
  });
});
