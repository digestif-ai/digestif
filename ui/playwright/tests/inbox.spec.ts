import { expect, test } from '../fixtures.ts';

// The Inbox pages (DES-51007, design/digestif/inbox.html): the Inbox, New item, and each kind's item
// page. The node keeps items from ISS-52609; until then these run against the mock node only.
test.beforeEach(async ({ request }) => {
  test.skip(process.env['DIGESTIF_NODE'] !== undefined, 'the node keeps items from ISS-52609; the mock plays them');
  const headers = { 'Digestif-Local': '1' };
  await request.post('/api/v0/_reset', { headers });
  await request.put('/api/v0/sources', { data: { selected: [] }, headers });
});

const row = (page: import('@playwright/test').Page, title: string | RegExp) => page.getByTestId('item-row').filter({ hasText: title });

test('the Inbox lists Draft and New first, counts them beside Inbox, and filters by status', async ({ page }) => {
  await page.goto('/inbox');
  const rows = page.getByTestId('item-row');
  await expect(rows.first()).toBeVisible();
  const nav = page.getByRole('navigation', { name: 'Sections' }).getByRole('link', { name: /Inbox/ });
  await expect(nav).toContainText('4');
  await expect(row(page, 'Introduce Ben to Cy')).toContainText('Draft');
  await page.getByRole('navigation', { name: 'Filter by status' }).getByRole('link', { name: 'Done' }).click();
  await expect(page).toHaveURL(/\/inbox\?status=done$/);
  await expect(rows).toHaveCount(2);
  await expect(row(page, 'nightly writer')).toContainText('Done');
});

test('opening a New question makes it Read; Not for me makes it Done', async ({ page }) => {
  await page.goto('/inbox');
  await row(page, 'eval sets').getByRole('link').first().click();
  await expect(page.getByTestId('item-subline')).toContainText("from Juno (Ben Ortiz's agent)");
  await expect(page.getByTestId('item-subline')).toContainText('to the circle');
  await expect(page.getByTestId('item-subline')).toContainText('Read');
  await expect(page.getByTestId('item-answer')).toHaveCount(2);
  await page.getByRole('button', { name: 'More actions' }).click();
  await page.getByRole('menuitem', { name: 'Not for me' }).click();
  await expect(page.getByTestId('item-done')).toContainText('not for you');
  await expect(page.getByTestId('item-subline')).toContainText('Done');
});

test('a question is answered on its page', async ({ page }) => {
  await page.goto('/inbox');
  await row(page, 'eval sets').getByRole('link').first().click();
  await page.getByLabel('Your answer').fill('We keep the eval set in its own repository.');
  await page.getByRole('button', { name: 'Answer', exact: true }).click();
  await expect(page.getByTestId('item-answer')).toHaveCount(3);
  await expect(page.getByTestId('item-answer').last()).toContainText('We keep the eval set in its own repository.');
  await expect(page.getByTestId('item-done')).toContainText('You answered it.');
});

test("an agent's draft is edited in place, its words kept, and sent", async ({ page }) => {
  await page.goto('/inbox');
  await row(page, 'Introduce Ben to Cy').getByRole('link').first().click();
  await expect(page.getByTestId('item-subline')).toContainText('drafted by Hermes (your agent)');
  await expect(page.getByTestId('item-subline')).toContainText('to Ben Ortiz, Cy Lund');
  await page.getByRole('button', { name: 'More actions' }).click();
  await page.getByRole('menuitem', { name: 'Edit' }).click();
  const form = page.getByRole('form', { name: 'Edit the draft' });
  await form.getByLabel('Detail').fill('Ben, Cy: a fake clock, half an hour. Ada');
  await form.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByTestId('item-detail')).toHaveText('Ben, Cy: a fake clock, half an hour. Ada');
  await expect(page.getByTestId('item-drafted')).toContainText('you are both fighting timer tests');
  await page.getByRole('button', { name: 'Send' }).click();
  await expect(page.getByTestId('item-subline')).toContainText('Read');
  await expect(page.getByRole('button', { name: 'Send' })).toHaveCount(0);
});

test('a draft is discarded', async ({ page }) => {
  await page.goto('/inbox');
  await row(page, 'Introduce Ben to Cy').getByRole('link').first().click();
  await page.getByRole('button', { name: 'More actions' }).click();
  await page.getByRole('menuitem', { name: 'Discard' }).click();
  await page.getByRole('button', { name: 'Discard' }).click();
  await expect(page).toHaveURL(/\/inbox$/);
  await expect(row(page, 'Introduce Ben to Cy')).toHaveCount(0);
});

test('work links what the review names, and Acknowledge dismisses it', async ({ page }) => {
  await page.goto('/inbox');
  await row(page, 'revoked_key').getByRole('link').first().click();
  await expect(page.getByTestId('item-review').getByRole('link', { name: 'digestif-ai/digestif#312' })).toHaveAttribute(
    'href',
    'https://github.com/digestif-ai/digestif/issues/312'
  );
  await page.getByRole('button', { name: 'Acknowledge' }).click();
  await expect(page.getByTestId('item-done')).toContainText('You acknowledged it.');
});

test('a choice is picked once', async ({ page }) => {
  await page.goto('/inbox');
  await row(page, 'standup behavior').getByRole('link').first().click();
  await page.getByRole('button', { name: 'Not now' }).click();
  await expect(page.getByTestId('item-done')).toContainText('You picked. Not now');
  await expect(page.getByRole('button', { name: 'Install' })).toHaveCount(0);
});

test("the asker names a different answer than the agent's close, and the agent's is kept beside it", async ({ page }) => {
  await page.goto('/inbox?status=done');
  await row(page, 'nightly writer').getByRole('link').first().click();
  await expect(page.getByTestId('item-closed')).toContainText(/by Hermes, \dd ago, on Ben Ortiz's answer/);
  await page.getByRole('button', { name: 'More actions' }).click();
  await page.getByRole('menuitem', { name: 'Name a different answer' }).click();
  await page.getByRole('button', { name: 'This unblocked it' }).click();
  await expect(page.getByTestId('item-closed')).toContainText("by you, just now, on Cy Lund's answer");
  await expect(page.getByTestId('item-agent-close')).toContainText("on Ben Ortiz's answer");
  await page.getByRole('button', { name: 'More actions' }).click();
  await page.getByRole('menuitem', { name: 'Reopen' }).click();
  await expect(page.getByTestId('item-closed')).toHaveCount(0);
  await expect(page.getByLabel('Your answer')).toHaveCount(0);
});

test('New item saves a question to the circle as a draft, and sends an intro to two named members', async ({ page }) => {
  await page.goto('/inbox');
  await page.getByRole('link', { name: 'New item' }).click();
  await expect(page).toHaveURL(/\/inbox\/new$/);
  const form = page.getByRole('form', { name: 'New item' });
  await expect(form.getByLabel('The circle')).toBeChecked();
  await form.getByLabel('Title').fill('Has anyone sharded a D1 database by tenant?');
  await form.getByLabel('Detail').fill('The log table grows about 2 GB a month.');
  await form.getByRole('button', { name: 'Save draft' }).click();
  await expect(page.getByTestId('item-subline')).toContainText('Draft');
  await expect(page.getByTestId('item-subline')).toContainText('to the circle');

  await page.goto('/inbox/new');
  await form.getByLabel('Kind').selectOption({ label: 'Intro' });
  await form.getByLabel('Ben Ortiz').check();
  await form.getByLabel('Title').fill('Ben, meet Cy');
  await form.getByRole('button', { name: 'Send' }).click();
  await expect(form).toContainText('two people');
  await form.getByLabel('Cy Lund').check();
  await form.getByRole('button', { name: 'Send' }).click();
  await expect(page.getByTestId('item-subline')).toContainText('Intro');
  await expect(page.getByTestId('item-subline')).toContainText('to Ben Ortiz, Cy Lund');
  await expect(page.getByTestId('item-subline')).toContainText('Read');
});
