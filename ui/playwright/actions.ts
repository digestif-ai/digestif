// A page header holds at most one button, its Actions menu (ISS-85465): these choose an act from it
// and read which acts it offers.
import { expect, type Page } from '@playwright/test';

/** The header's menu button, whatever it reads: "Actions", or the verb of a request in flight. */
const menuButton = (page: Page) => page.getByTestId('page-header').locator('button[aria-haspopup="menu"]');

/**
 * Opens the header's Actions menu and chooses `name`. Right after a client-side navigation the
 * previous page, with its own Actions menu, stays on screen until the next page's data loads, so a
 * menu opened then can be the old page's and vanish with it: the menu is reopened until it offers
 * `name`.
 */
export async function chooseAction(page: Page, name: string): Promise<void> {
  const item = page.getByRole('menuitem', { name, exact: true });
  await expect(async () => {
    if (!(await item.isVisible())) {
      await page.keyboard.press('Escape');
      await page.getByRole('button', { name: 'Actions', exact: true }).click({ timeout: 5_000 });
    }
    await expect(item).toBeVisible({ timeout: 2_000 });
  }).toPass();
  await item.click();
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
