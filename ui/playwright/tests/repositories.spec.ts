import { expect, test } from '@playwright/test';

// The repositories page (DES-37265, Repositories): the demo node and the mock seed the same
// organizations, repositories and commit authors (node/web/demo.ml, ui/mock/repositories.ts).
test.beforeEach(async ({ request }) => {
  await request.post('/api/v0/_reset', { headers: { 'Digestif-Local': '1' } });
  await request.put('/api/v0/sources', { data: { selected: [] }, headers: { 'Digestif-Local': '1' } });
});

test('each organization shows its choice and each repository its status', async ({ page }) => {
  await page.goto('/sources');
  await page.getByRole('link', { name: 'Repositories' }).click();
  await expect(page).toHaveURL(/\/settings\/repositories\/edit$/);
  await expect(page.getByRole('heading', { name: 'Repositories' })).toBeVisible();

  const example = page.getByTestId('org-example-co');
  await expect(example.getByLabel('All repositories in example-co')).toBeChecked();
  await expect(example.getByLabel('Read new repositories automatically')).not.toBeChecked();
  await expect(example.getByTestId('repo-web')).toContainText('Declined');
  await expect(example.getByLabel('Read web')).not.toBeChecked();
  await expect(example.getByTestId('repo-loader')).toContainText('Approved');

  const acme = page.getByTestId('org-acme-labs');
  await expect(acme.getByLabel('Chosen repositories')).toBeChecked();
  await expect(acme.getByTestId('repo-prototype')).toContainText('Undecided');

  await expect(page.getByTestId('author-ada@example.com')).toBeVisible();
});

test('search and the status filter narrow the list', async ({ page }) => {
  await page.goto('/settings/repositories/edit');
  await page.getByRole('button', { name: 'Undecided' }).click();
  await expect(page.getByTestId('repo-prototype')).toBeVisible();
  await expect(page.getByTestId('org-example-co')).toHaveCount(0);
  await page.getByRole('button', { name: /^All/ }).click();
  await page.getByLabel('Search repositories').fill('load');
  await expect(page.getByTestId('repo-loader')).toBeVisible();
  await expect(page.getByTestId('repo-importer')).toHaveCount(0);
});

test('unchecking under All declines and keeps the choice; Save sends every change', async ({ page }) => {
  await page.goto('/settings/repositories/edit');
  const ada = page.getByTestId('org-ada-park');
  await ada.getByLabel('Read side-project').uncheck();
  await expect(ada.getByTestId('repo-side-project')).toContainText('Declined');
  await expect(ada.getByLabel('All repositories in ada-park')).toBeChecked();

  // Choosing All shows what it approves before Save.
  const acme = page.getByTestId('org-acme-labs');
  await acme.getByLabel('All repositories in acme-labs').check();
  await expect(acme.getByTestId('repo-prototype')).toContainText('Approved');

  await page.getByLabel('Whose is hermes-bot@example.com').selectOption({ label: 'Yours' });
  await page.getByRole('button', { name: 'Add identity' }).click();
  const form = page.getByRole('form', { name: 'Add identity' });
  await form.getByLabel('Email').fill('ada@work.example');
  await form.getByRole('button', { name: 'Add' }).click();
  await expect(page.getByTestId('author-ada@work.example')).toBeVisible();

  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page).toHaveURL(/\/sources$/);

  await page.goto('/settings/repositories/edit');
  await expect(page.getByTestId('org-ada-park').getByTestId('repo-side-project')).toContainText('Declined');
  await expect(page.getByTestId('org-ada-park').getByLabel('All repositories in ada-park')).toBeChecked();
  await expect(page.getByTestId('org-acme-labs').getByTestId('repo-prototype')).toContainText('Approved');
  await expect(page.getByLabel('Whose is hermes-bot@example.com')).toHaveValue('yours');
  await expect(page.getByTestId('author-ada@work.example')).toBeVisible();
});

test('Cancel drops every staged change, and a removed author is gone after Save', async ({ page }) => {
  await page.goto('/settings/repositories/edit');
  await page.getByTestId('org-example-co').getByLabel('Read loader').uncheck();
  await page.getByRole('link', { name: 'Cancel' }).click();
  await page.goto('/settings/repositories/edit');
  await expect(page.getByTestId('org-example-co').getByTestId('repo-loader')).toContainText('Approved');

  await page.getByRole('button', { name: 'Remove hermes-bot@example.com' }).click();
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page).toHaveURL(/\/sources$/);
  await page.goto('/settings/repositories/edit');
  await expect(page.getByTestId('author-hermes-bot@example.com')).toHaveCount(0);
});
