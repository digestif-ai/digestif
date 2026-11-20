// A page header holds at most one button, its Actions menu (ISS-85465): these choose an act from it
// and read which acts it offers.
import { expect, type Frame, type Page } from '@playwright/test';

/** The header's menu button, whatever it reads: "Actions", or the verb of a request in flight. */
const menuButton = (page: Page) => page.getByTestId('page-header').locator('button[aria-haspopup="menu"]');

/** How long the main frame must go without a navigation before the page counts as settled. */
const QUIET_MS = 400;

/**
 * Waits until the page's main frame has gone `QUIET_MS` without navigating. Right after a `goto`, or
 * an act that reloads the page, the page can navigate again (a load function's invalidation, vite
 * reloading a re-optimized dependency): a menu opened in between closes under the reload. Bounded by
 * `timeout`, after which the callers' own retries take over.
 */
export async function settled(page: Page, timeout = 5_000): Promise<void> {
  let last = Date.now();
  const onNavigated = (frame: Frame): void => {
    if (frame === page.mainFrame()) last = Date.now();
  };
  page.on('framenavigated', onNavigated);
  try {
    await page.waitForLoadState('load', { timeout }).catch(() => undefined);
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline && Date.now() - last < QUIET_MS) {
      await page.waitForTimeout(QUIET_MS - (Date.now() - last));
    }
  } finally {
    page.off('framenavigated', onNavigated);
  }
}

/** How long `chooseAction` keeps reopening the menu: inside a test's 30s, so a red names the menu, not the test budget. */
const CHOOSE_MS = 15_000;

/**
 * Opens the header's Actions menu and chooses `name`. Right after a client-side navigation the
 * previous page, with its own Actions menu, stays on screen until the next page's data loads, so a
 * menu opened then can be the old page's and vanish with it, or close under a late reload of the
 * page: it first waits for the page to settle, then reopens the menu until the click on `name`
 * lands, for at most `CHOOSE_MS`.
 */
export async function chooseAction(page: Page, name: string): Promise<void> {
  await settled(page);
  const item = page.getByRole('menuitem', { name, exact: true });
  await expect(async () => {
    if (!(await item.isVisible())) {
      if (
        (await menuButton(page)
          .getAttribute('aria-expanded', { timeout: 1_000 })
          .catch(() => null)) === 'true'
      ) {
        await page.keyboard.press('Escape');
      }
      await page.getByRole('button', { name: 'Actions', exact: true }).click({ timeout: 3_000 });
    }
    await expect(item).toBeVisible({ timeout: 2_000 });
    await item.click({ timeout: 2_000 });
  }).toPass({ timeout: CHOOSE_MS, intervals: [250, 500, 1_000] });
}

/** How long one read of the menu waits on its button before the poll reads again. */
const READ_MS = 1000;

/**
 * The acts the header's menu offers now, read by opening it and closing it again: none when the page
 * has no menu, and `busy` while a request it sent is in flight, so a poll waits that out. The page
 * reloads after an act, so the button can go between the count and the next read: each read waits a
 * moment and answers `changing` rather than waiting out the poll on a button that is gone.
 */
export async function headerActions(page: Page): Promise<string[]> {
  const button = menuButton(page);
  if ((await button.count()) === 0) return [];
  try {
    if (await button.isDisabled({ timeout: READ_MS })) return ['busy'];
    await button.click({ timeout: READ_MS });
  } catch {
    return ['changing'];
  }
  const items = await page.getByRole('menuitem').allInnerTexts();
  await page.keyboard.press('Escape');
  return items.map((t) => t.trim());
}
