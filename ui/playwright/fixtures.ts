// The suite's `test`: Playwright's own, whose page records what it loaded so a failed test's report
// says why the page never showed what the test waited for. A shard runs on a cloud runner that is gone
// by the time anyone reads its red, and its trace.zip with it, so the evidence has to be in the log.
import { test as base, type Page, type Request } from '@playwright/test';

export { expect } from '@playwright/test';

/** How long the report waits on a page that may itself be stalled. */
const READ_MS = 2000;
/** How much of the page's text the report carries. */
const TEXT_CHARS = 1500;

interface PageRecord {
  started: number;
  events: string[];
  pending: Map<Request, number>;
}

export const test = base.extend({
  page: async ({ page }, use, testInfo) => {
    const record = watch(page);
    await use(page);
    if (testInfo.status === testInfo.expectedStatus) return;
    const body = await report(page, record);
    await testInfo.attach('page diagnostics', { body, contentType: 'text/plain' });
    // The list reporter cuts a text attachment at 300 characters; the log has to carry all of it.
    console.log(
      ['', '--- page diagnostics: ' + testInfo.titlePath.join(' > ') + ' [' + testInfo.project.name + ']', body, '---'].join('\n')
    );
  }
});

function watch(page: Page): PageRecord {
  const record: PageRecord = { started: Date.now(), events: [], pending: new Map() };
  const note = (line: string): void => {
    record.events.push(elapsed(record.started, Date.now()) + ' ' + line);
  };
  page.on('request', (r) => record.pending.set(r, Date.now()));
  page.on('requestfinished', (r) => record.pending.delete(r));
  page.on('requestfailed', (r) => {
    record.pending.delete(r);
    note('request failed: ' + r.method() + ' ' + short(r.url()) + ' (' + (r.failure()?.errorText ?? 'no reason') + ')');
  });
  page.on('response', (r) => {
    if (r.status() >= 400) note('response ' + String(r.status()) + ': ' + r.request().method() + ' ' + short(r.url()));
  });
  page.on('framenavigated', (f) => {
    if (f === page.mainFrame()) note('navigated: ' + short(f.url()));
  });
  page.on('pageerror', (e) => note('page error: ' + e.message));
  page.on('console', (m) => {
    if (m.type() === 'error' || m.type() === 'warning') note('console ' + m.type() + ': ' + m.text());
  });
  return record;
}

async function report(page: Page, record: PageRecord): Promise<string> {
  const now = Date.now();
  const pending = [...record.pending].map(
    ([r, at]) => '  ' + r.method() + ' ' + short(r.url()) + ', open ' + elapsed(at, now) + ' (since ' + elapsed(record.started, at) + ')'
  );
  const text = page.isClosed()
    ? 'the page is closed'
    : await page
        .locator('body')
        .innerText({ timeout: READ_MS })
        .catch((e: unknown) => 'the page could not be read: ' + (e instanceof Error ? e.message.split('\n')[0] : String(e)));
  return [
    'url: ' + (page.isClosed() ? 'closed' : short(page.url())),
    'events (seconds since the page opened):',
    ...(record.events.length === 0 ? ['  none'] : record.events.map((e) => '  ' + e)),
    'requests still open:',
    ...(pending.length === 0 ? ['  none'] : pending),
    'page text:',
    text.trim().slice(0, TEXT_CHARS)
  ].join('\n');
}

function elapsed(from: number, to: number): string {
  return ((to - from) / 1000).toFixed(1) + 's';
}

/** A URL on the suite's own server, without its origin. */
function short(url: string): string {
  try {
    const u = new URL(url);
    return u.hostname === '127.0.0.1' || u.hostname === 'localhost' ? u.pathname + u.search : url;
  } catch {
    return url;
  }
}
