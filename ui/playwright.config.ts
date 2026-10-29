import { defineConfig, devices } from '@playwright/test';

/** The suite drives `vite dev` against the mock node; PORT picks a free port on a shared machine. */
const PORT = Number(process.env['PORT'] ?? '5391');

export default defineConfig({
  testDir: 'playwright/tests',
  fullyParallel: false,
  workers: 1,
  reporter: 'list',
  use: { baseURL: 'http://127.0.0.1:' + String(PORT), trace: 'retain-on-failure' },
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
