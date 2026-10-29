import { defineConfig, devices } from '@playwright/test';

/** The suite drives `vite dev` against the mock node; PORT picks a free port on a shared machine. */
const PORT = Number(process.env['PORT'] ?? '5391');

/**
 * With DIGESTIF_NODE set, vite proxies /api/v0 to that node instead, and DIGESTIF_NODE_LAUNCH is
 * its one-time launch link, spent once to give every test the node's session cookie.
 * `playwright/against-node.sh` starts a `digestif demo` node and sets both.
 */
const AGAINST_NODE = process.env['DIGESTIF_NODE'] !== undefined;

export default defineConfig({
  testDir: 'playwright/tests',
  fullyParallel: false,
  workers: 1,
  reporter: 'list',
  ...(AGAINST_NODE ? { globalSetup: './playwright/node-session.ts' } : {}),
  use: {
    baseURL: 'http://127.0.0.1:' + String(PORT),
    trace: 'retain-on-failure',
    ...(AGAINST_NODE ? { storageState: 'playwright/.auth/node.json' } : {})
  },
  projects: [
    { name: 'desktop', use: { ...devices['Desktop Chrome'] } },
    { name: 'mobile', use: { ...devices['Pixel 7'] } }
  ],
  webServer: {
    command: 'npx vite dev --host 127.0.0.1 --strictPort --port ' + String(PORT),
    url: 'http://127.0.0.1:' + String(PORT),
    reuseExistingServer: false
  }
});
