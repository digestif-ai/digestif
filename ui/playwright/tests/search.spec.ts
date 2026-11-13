import { expect, test } from '../fixtures.ts';

// Global search (DIG-475): the box in the shell on every page, one query over the Inbox, the feed,
// notes, members and the settings pages, results grouped by kind. Runs on the desktop and phone projects.
test.beforeEach(async ({ request }) => {
  test.skip(process.env['DIGESTIF_NODE'] !== undefined, 'the mock node plays the fixtures the search reads');
  const headers = { 'Digestif-Local': '1' };
  await request.post('/api/v0/_reset', { headers });
  // a node with no source chosen is on its first run, which has no navigation and no search
  await request.put('/api/v0/sources', { data: { selected: [] }, headers });
});

import type { Page } from '@playwright/test';

/** On a phone the box is behind a magnifier; on a wide screen it is already there. */
async function openBox(page: Page): Promise<void> {
  // the magnifier shows below Tailwind's sm breakpoint (640px), once the status has come
  if ((page.viewportSize()?.width ?? 1280) < 640) await page.getByTestId('search-toggle').click();
  await expect(page.getByTestId('search-box')).toBeVisible();
}

test('the box is on every page and a query lists items, members and settings pages by kind', async ({ page }) => {
  for (const path of ['/inbox', '/feed', '/members', '/settings']) {
    await page.goto(path);
    await openBox(page);
  }
  await page.goto('/members');
  await openBox(page);
  await page.getByTestId('search-box').fill('eval');
  await page.getByTestId('search-box').press('Enter');
  await expect(page).toHaveURL(/\/search\?q=eval$/);
  await expect(page.getByTestId('search-group-inbox')).toContainText('How do you keep eval sets from leaking');
  await expect(page.getByTestId('search-box')).toHaveValue('eval');
  await page.getByTestId('search-box').fill('ada');
  await page.getByTestId('search-box').press('Enter');
  await expect(page.getByTestId('search-group-members')).toContainText('Ada Park');
  await page.getByTestId('search-group-members').getByTestId('search-hit').first().click();
  await expect(page).toHaveURL(/\/members\//);
});

test('a settings page is found by what it holds, and a query with no match says so', async ({ page }) => {
  await page.goto('/search?q=quiet');
  const settings = page.getByTestId('search-group-settings');
  await expect(settings).toContainText('Quiet hours');
  await settings.getByRole('link', { name: /Quiet hours/ }).click();
  await expect(page).toHaveURL(/\/settings\/quiet-hours$/);
  await page.goto('/search?q=zzzqqq');
  await expect(page.getByText('Nothing matches that.')).toBeVisible();
});

test('the page is not wider than the screen', async ({ page }) => {
  await page.goto('/search?q=a');
  await openBox(page);
  const wide = await page.locator('html').evaluate((el) => el.scrollWidth > el.clientWidth);
  expect(wide).toBe(false);
});

test('on a phone the magnifier opens the box in the header row, and the page says what is searched', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== 'mobile', 'the magnifier is the phone layout');
  await page.goto('/inbox');
  await expect(page.getByTestId('search-box')).toBeHidden();
  await page.getByTestId('search-toggle').click();
  await expect(page.getByTestId('search-box')).toBeFocused();
  await page.getByTestId('search-box').fill('eval');
  await page.getByTestId('search-box').press('Enter');
  await expect(page.getByTestId('search-scope')).toHaveText('Search reads titles and previews.');
});
