import { createHash } from 'node:crypto';
import { expect, test } from '@playwright/test';

test.beforeEach(async ({ request }) => {
  await request.post('/api/v0/_reset', { headers: { 'Digestif-Local': '1' } });
});

test('first run is a source picker with nothing selected and a first-note preview', async ({ page }) => {
  await page.goto('/');
  await expect(page).toHaveURL(/\/sources\/edit$/);
  await expect(page.getByRole('heading', { name: 'Choose what your agent may read' })).toBeVisible();
  await expect(page.getByTestId('source-git')).not.toBeChecked();
  await expect(page.getByTestId('source-claude-code')).not.toBeChecked();
  await expect(page.getByRole('navigation', { name: 'Sections' })).toHaveCount(0);

  await page.getByTestId('source-git').check();
  await page.getByRole('button', { name: 'Preview' }).click();
  await expect(page.getByTestId('preview-text')).toContainText('Worked on');
  await expect(page.getByTestId('preview')).toContainText('commit: Add a retry queue');

  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page).toHaveURL(/\/feed$/);
  await page.getByRole('link', { name: 'Sources', exact: true }).click();
  await expect(page.getByRole('list', { name: 'Chosen sources' })).toContainText('Git repositories');
});

test('joining with no sources is one click', async ({ page }) => {
  await page.goto('/sources/edit');
  await page.getByRole('button', { name: 'Join with no sources' }).click();
  await expect(page).toHaveURL(/\/feed$/);
});

test.describe('after first run', () => {
  test.beforeEach(async ({ request }) => {
    await request.put('/api/v0/sources', { data: { selected: [] }, headers: { 'Digestif-Local': '1' } });
  });

  test('feed rows are links and the compose box posts as the person', async ({ page }) => {
    await page.goto('/feed');
    const rows = page.getByTestId('feed-row');
    await expect(rows.first()).toBeVisible();
    await page.getByLabel('Write to the circle').fill('Hosting dinner 3 on the 20th.');
    await page.getByRole('button', { name: 'Post' }).click();
    await expect(rows.first()).toContainText('Hosting dinner 3 on the 20th.');
    await expect(rows.first()).toContainText('Ada Park');
    await rows.first().click();
    await expect(page.getByTestId('message-text')).toHaveText('Hosting dinner 3 on the 20th.');
    await expect(page.getByText('written by the person')).toBeVisible();
  });

  test('a post the deny layer trips is refused and names the rule', async ({ page }) => {
    await page.goto('/feed');
    await page.getByLabel('Write to the circle').fill('notes at internal.example.com');
    await page.getByRole('button', { name: 'Post' }).click();
    await expect(page.getByRole('status')).toContainText('refused by deny: domain');
  });

  test('an ask is answered on its detail page', async ({ page }) => {
    await page.goto('/asks');
    await page.getByTestId('ask-row').filter({ hasText: 'Intro Ben to Cy' }).click();
    await page.getByRole('button', { name: 'Make the intro (recommended)' }).click();
    await expect(page.getByTestId('ask-answer')).toContainText('Make the intro');
  });

  test('members show when each last posted, and a member can be muted', async ({ page }) => {
    await page.goto('/members');
    await expect(page.getByTestId('member-row').filter({ hasText: 'Dee Rao' })).toContainText('Silent');
    await page.getByTestId('member-row').filter({ hasText: 'Ben Ortiz' }).click();
    await page.getByRole('button', { name: 'Mute' }).click();
    await expect(page.getByRole('button', { name: 'Unmute' })).toBeVisible();
    await expect(page.getByText('Muted: filtered before your agent reads them')).toBeVisible();
  });

  test("a phone is paired from the member's own page", async ({ page }) => {
    const keys = Buffer.alloc(64, 9);
    const code = 'p1.' + keys.toString('base64url') + '.' + createHash('sha256').update(keys).digest().subarray(0, 3).toString('base64url');
    await page.goto('/members');
    await page.getByTestId('member-row').filter({ hasText: 'Ada Park' }).click();
    await expect(page.getByRole('list').filter({ hasText: 'device' }).getByRole('listitem')).toHaveCount(1);
    await page.getByRole('link', { name: 'Add a phone' }).click();
    await page.getByLabel('Pairing code').fill(code.slice(0, -1) + (code.endsWith('A') ? 'B' : 'A'));
    await page.getByLabel('Recovery phrase').fill(Array.from({ length: 24 }, () => 'abandon').join(' '));
    await page.getByRole('button', { name: 'Add phone' }).click();
    await expect(page.getByText("The pairing code's check does not match; retype it.")).toBeVisible();
    await page.getByLabel('Pairing code').fill(code);
    await page.getByRole('button', { name: 'Add phone' }).click();
    await expect(page.getByRole('heading', { name: 'Ada Park' })).toBeVisible();
    await expect(page.getByRole('list').filter({ hasText: 'device' }).getByRole('listitem')).toHaveCount(2);
  });

  test('a dinner lists its guests', async ({ page }) => {
    await page.goto('/dinners');
    await page.getByTestId('dinner-row').first().click();
    await expect(page.getByRole('list', { name: 'Guests' })).toContainText('Eve Moss');
    await expect(page.getByRole('list', { name: 'Guests' })).toContainText('Invited');
  });

  test('the brief is read on its page and edited on its own', async ({ page }) => {
    await page.goto('/brief');
    await page.getByRole('link', { name: 'Edit' }).click();
    await page.getByLabel('Brief').fill('I build developer tools.');
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page).toHaveURL(/\/brief$/);
    await expect(page.getByTestId('brief-text')).toHaveText('I build developer tools.');
  });

  test('deny entries are added on the rules page and removed on their own', async ({ page }) => {
    await page.goto('/rules');
    await page.getByRole('button', { name: 'Add' }).click();
    await page.getByLabel('Kind').selectOption('name');
    await page.getByLabel('Value').fill('Acme Corp');
    await page.getByRole('button', { name: 'Add' }).click();
    await page.getByTestId('deny-row').filter({ hasText: 'Acme Corp' }).click();
    await page.getByRole('button', { name: 'Remove from deny list' }).click();
    await page.getByRole('button', { name: 'Remove', exact: true }).click();
    await expect(page).toHaveURL(/\/rules$/);
    await expect(page.getByTestId('deny-row').filter({ hasText: 'Acme Corp' })).toHaveCount(0);
  });

  test('one of the first five notes is approved before it travels', async ({ page }) => {
    await page.goto('/approvals');
    await expect(page.getByTestId('approval-progress')).toHaveText('1 of 5 approved');
    await page.getByTestId('approval-row').filter({ hasText: 'Awaiting approval' }).click();
    await page.getByRole('button', { name: 'Approve and post' }).click();
    await expect(page.getByRole('button', { name: 'Approve and post' })).toHaveCount(0);
    await page.getByRole('link', { name: 'Approvals', exact: true }).first().click();
    await expect(page.getByTestId('approval-progress')).toHaveText('2 of 5 approved');
  });
});
