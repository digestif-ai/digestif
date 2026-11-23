import { mkdirSync } from 'node:fs';
import { defineConfig, devices } from '@playwright/test';

/**
 * On a Fly builder the fleet names a directory here (devops Chromium_net_log, ISS-114501): Chromium
 * writes its net log into it, one file per worker process, and the test ledger reads what its
 * network-change notifier saw beside a net::ERR_NETWORK_CHANGED failure. A log keeps its newest
 * 20 MB, a few specs' worth: a failure ends its worker's browser, so the newest events are the ones
 * around it, and an unbounded log runs to gigabytes over a suite.
 */
const NET_LOG_DIR = process.env['DEV_CHROMIUM_NET_LOG_DIR'];
if (NET_LOG_DIR) mkdirSync(NET_LOG_DIR, { recursive: true });
const netLog = NET_LOG_DIR
  ? {
      launchOptions: {
        args: [`--log-net-log=${NET_LOG_DIR}/${String(process.pid)}-${String(Date.now())}.json`, '--net-log-max-size-mb=20']
      }
    }
  : {};

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
  // spent only on an attempt the machine failed (playwright/faults.ts); playwright/fixtures.ts fails any other retry
  retries: 1,
  // infra-reporter: a run whose every red is the machine's exits 75 through playwright/run.sh
  reporter: [['list'], ['./playwright/infra-reporter.ts']],
  ...(AGAINST_NODE ? { globalSetup: './playwright/node-session.ts' } : {}),
  use: {
    baseURL: 'http://127.0.0.1:' + String(PORT),
    trace: 'retain-on-failure',
    ...(AGAINST_NODE ? { storageState: 'playwright/.auth/node.json' } : {}),
    ...netLog
  },
  projects: [
    { name: 'desktop', use: { ...devices['Desktop Chrome'] } },
    { name: 'mobile', use: { ...devices['Pixel 7'] } }
  ],
  webServer: {
    command: 'npx vite dev --host 127.0.0.1 --strictPort --port ' + String(PORT),
    url: 'http://127.0.0.1:' + String(PORT),
    reuseExistingServer: false,
    // vite's own log (requests, dependency re-optimization, full reloads) beside a red in the shard log
    stdout: 'pipe'
  }
});
