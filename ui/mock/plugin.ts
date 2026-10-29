// Mounts the mock node at /api/v0 in `vite dev`, unless DIGESTIF_NODE names a running node, in which
// case vite proxies to it instead. POST /api/v0/_reset reseeds, for the end-to-end tests.
import type { Plugin } from 'vite';
import { MockNode } from './node.ts';

export function mockNode(): Plugin {
  const node = new MockNode();
  return {
    name: 'digestif-mock-node',
    apply: 'serve',
    configureServer(server): void {
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
