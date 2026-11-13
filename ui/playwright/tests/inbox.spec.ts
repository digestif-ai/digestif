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

test('the Inbox opens with Draft, New and Read checked, Draft and New first, and each status toggles', async ({ page }) => {
  await page.goto('/inbox');
  const rows = page.getByTestId('item-row');
  await expect(rows.first()).toBeVisible();
  const nav = page.getByRole('navigation', { name: 'Sections' }).getByRole('link', { name: /Inbox/ });
  await expect(nav).toContainText('4');
  await expect(row(page, 'Introduce Ben to Cy')).toContainText('Draft');
  const check = (name: string) =>
    page.getByRole('navigation', { name: 'Filter by status' }).getByRole('link', { name: new RegExp(`^(Showing )?${name}$`) });
  for (const s of ['Draft', 'New', 'Read']) await expect(check(s)).toHaveAttribute('aria-current', 'true');
  await expect(check('Done')).not.toHaveAttribute('aria-current');
  await expect(row(page, 'nightly writer')).toHaveCount(0);
  await check('Done').click();
  await expect(page).toHaveURL(/\/inbox\?status=draft&status=new&status=read&status=done$/);
  await expect(row(page, 'nightly writer')).toContainText('Done');
  await expect(row(page, 'Introduce Ben to Cy')).toContainText('Draft');
  for (const s of ['Draft', 'New', 'Read']) await check(s).click();
  await expect(page).toHaveURL(/\/inbox\?status=done$/);
  await expect(rows).toHaveCount(2);
  await check('Done').click();
  await expect(rows).toHaveCount(0);
  for (const s of ['Draft', 'New', 'Read']) await check(s).click();
  await expect(page).toHaveURL(/\/inbox$/);
});

test("each row says whom it is from, and the member's own unanswered question is not listed (ISS-64736)", async ({ page }) => {
  await page.goto('/inbox?status=draft&status=new&status=read&status=done');
  await expect(row(page, 'eval sets').getByTestId('item-from')).toHaveText('Juno');
  await expect(row(page, 'eval sets').getByTestId('item-from').getByRole('link')).toHaveAttribute('title', "Ben Ortiz's agent");
  await expect(row(page, 'nightly writer').getByTestId('item-from')).toHaveText('Hermes');
  await expect(row(page, 'relay region')).toHaveCount(0);
});

test('an item from a message shows the paragraph it came from, the words that produced it marked, and links the full message (ISS-85463)', async ({
  page
}) => {
  await page.goto('/inbox/itm-work');
  const source = page.getByTestId('item-source');
  await expect(source).toContainText('Rotated my laptop key on Tuesday');
  await expect(page.getByTestId('item-source-quote')).toHaveText('The relay answered fork, where the protocol says revoked_key');
  await expect(source.getByRole('link', { name: 'The full message' })).toHaveAttribute('href', /^\/feed\/sha256/);
  await page.goto('/inbox/itm-reply');
  await expect(page.getByTestId('item-source')).toHaveCount(0);
  await expect(page.getByRole('link', { name: 'the message it came from' })).toBeVisible();
});

test('opening a New question makes it Read; Not for me makes it Done', async ({ page }) => {
  await page.goto('/inbox');
  await row(page, 'eval sets').getByRole('link').first().click();
  await expect(page.getByTestId('item-sender')).toHaveText('from Juno');
  await expect(page.getByTestId('item-sender').getByRole('link', { name: "Juno, Ben Ortiz's agent" })).toHaveAttribute(
    'href',
    /\/members\//
  );
  await expect(page.getByTestId('item-subline')).toContainText('to the circle');
  await expect(page.getByTestId('item-subline')).toContainText('Read');
  await expect(page.getByTestId('item-answer')).toHaveCount(2);
  await page.getByRole('button', { name: 'More actions' }).click();
  await page.getByRole('menuitem', { name: 'Not for me' }).click();
  await expect(page.getByTestId('item-done')).toContainText('not for you');
  await expect(page.getByTestId('item-subline')).toContainText('Done');
});

test("a work notice about a note carries the agent's draft reply, which the member edits and sends as their own (ISS-83154)", async ({
  page
}) => {
  await page.goto('/inbox/itm-reply');
  const reply = page.getByRole('textbox', { name: 'Your reply' });
  await expect(reply).toHaveValue(/lib-util has a fake clock/);
  await expect(page.getByRole('button', { name: 'Acknowledge' })).toBeVisible();
  await reply.fill('Yes: lib-util has a fake clock. Ping me and I will show you.');
  await page.getByRole('button', { name: 'Send reply' }).click();
  await expect(reply).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Draft a reply' })).toBeVisible();
});

test('Draft a reply asks the agent for one on a work notice that has none, and reads Drafting… until it arrives (ISS-83154)', async ({
  page
}) => {
  await page.goto('/inbox/itm-work');
  await page.getByRole('button', { name: 'Draft a reply' }).click();
  await expect(page.getByRole('button', { name: 'Drafting…' })).toBeDisabled();
  await expect(page.getByRole('textbox', { name: 'Your reply' })).toHaveValue(/Thanks for asking/, { timeout: 15_000 });
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
  await expect(page.getByTestId('item-subline')).toContainText('drafted by Hermes to');
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
