// Mounts the mock node at /api/v0 in `vite dev`, unless DIGESTIF_NODE names a running node, in which
// case vite proxies to it instead, and a mock mailing relay at /v0 for the phone web app under /app.
// POST /api/v0/_reset and POST /v0/_reset reseed, for the end-to-end tests.
import type { Plugin } from 'vite';
import { MockNode } from './node.ts';
import { MockRelay } from './relay.ts';

export function mockNode(): Plugin {
  const node = new MockNode();
  return {
    name: 'digestif-mock-node',
    apply: 'serve',
    configureServer(server): void {
      const relay = new MockRelay(
        'http://' + (server.config.server.host === true ? 'localhost' : (server.config.server.host ?? 'localhost'))
      );
      server.middlewares.use('/v0', (req, res) => {
        const chunks: Buffer[] = [];
        req.on('data', (c: Buffer) => chunks.push(c));
        req.on('end', () => {
          const headers: Record<string, string | undefined> = {};
          for (const [k, v] of Object.entries(req.headers)) headers[k] = Array.isArray(v) ? v[0] : v;
          void relay.handle(req.method ?? 'GET', '/v0' + (req.url ?? ''), Buffer.concat(chunks).toString('utf8'), headers).then((out) => {
            res.statusCode = out.status;
            if (out.body === undefined) {
              res.end();
            } else {
              res.setHeader('Content-Type', 'application/json');
              res.end(JSON.stringify(out.body));
            }
          });
        });
      });
      if (process.env['DIGESTIF_NODE'] !== undefined) return;
      server.middlewares.use('/api/v0', (req, res) => {
        const chunks: Buffer[] = [];
        req.on('data', (c: Buffer) => chunks.push(c));
        req.on('end', () => {
          const url = '/api/v0' + (req.url ?? '');
          if (req.method === 'POST' && url.startsWith('/api/v0/_reset')) {
            node.reset();
            res.statusCode = 204;
            res.end();
            return;
          }
          if (req.headers['digestif-local'] !== '1') {
            res.statusCode = 403;
            res.end();
            return;
          }
          const raw = Buffer.concat(chunks).toString('utf8');
          const out = node.handle(req.method ?? 'GET', url, raw === '' ? undefined : (JSON.parse(raw) as unknown));
          res.statusCode = out.status;
          if (out.body === undefined) {
            res.end();
          } else {
            res.setHeader('Content-Type', 'application/json');
            res.end(JSON.stringify(out.body));
          }
        });
      });
    }
  };
}
