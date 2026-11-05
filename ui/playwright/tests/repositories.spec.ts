import { expect, test } from '../fixtures.ts';

// The repositories page (DES-37265, Repositories): the demo node and the mock seed the same
// organizations, repositories and commit authors (node/web/demo.ml, ui/mock/repositories.ts).
test.beforeEach(async ({ request }) => {
  await request.post('/api/v0/_reset', { headers: { 'Digestif-Local': '1' } });
  await request.put('/api/v0/sources', { data: { selected: [] }, headers: { 'Digestif-Local': '1' } });
});

test('each organization shows its choice and each repository its status', async ({ page }) => {
  await page.goto('/settings');
  await page.getByTestId('settings-repositories').getByRole('link', { name: 'Change' }).click();
  await expect(page).toHaveURL(/\/settings\/repositories\/edit$/);
  await expect(page.getByRole('heading', { name: 'Repositories' })).toBeVisible();

  const example = page.getByTestId('org-example-co');
  await expect(example.getByLabel('All repositories in example-co')).toBeChecked();
  await expect(example.getByLabel('Read new repositories automatically')).not.toBeChecked();
  await expect(example.getByTestId('repo-web')).toContainText('Declined');
  await expect(example.getByLabel('Read web')).not.toBeChecked();
  await expect(example.getByTestId('repo-loader')).toContainText('Approved');

  // acme-labs was found after setup and never confirmed, so it shows setup's three choices.
  const acme = page.getByTestId('org-acme-labs');
  await expect(acme.getByLabel('All repositories in acme-labs, ask me about new ones · Recommended')).toBeChecked();
  await expect(acme.getByTestId('found-prototype')).toContainText('new clone');

  await expect(page.getByTestId('author-ada@example.com')).toBeVisible();
});

test('each status chip shows its count, and the counts follow the search', async ({ page }) => {
  await page.goto('/settings/repositories/edit');
  const chips = page.getByRole('group', { name: 'Status' });
  await expect(chips.getByRole('button', { name: 'All 6' })).toBeVisible();
  await expect(chips.getByRole('button', { name: 'Approved 4' })).toBeVisible();
  await expect(chips.getByRole('button', { name: 'Declined 1' })).toBeVisible();
  await expect(chips.getByRole('button', { name: 'Undecided 1' })).toBeVisible();
  await page.getByLabel('Search repositories').fill('example');
  await expect(chips.getByRole('button', { name: 'All 3' })).toBeVisible();
  await expect(chips.getByRole('button', { name: 'Approved 2' })).toBeVisible();
  await expect(chips.getByRole('button', { name: 'Undecided 0' })).toBeVisible();
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
  await acme.getByLabel('All repositories in acme-labs, new ones read automatically').check();
  await expect(acme.getByTestId('repo-prototype')).toContainText('Approved');

  await page.getByLabel('Whose is hermes-bot@example.com').selectOption({ label: 'Yours' });
  await page.getByRole('button', { name: 'Add identity' }).click();
  const form = page.getByRole('form', { name: 'Add identity' });
  await form.getByLabel('Email').fill('ada@work.example');
  await form.getByRole('button', { name: 'Add' }).click();
  await expect(page.getByTestId('author-ada@work.example')).toBeVisible();

  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page).toHaveURL(/\/settings$/);

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
  await expect(page).toHaveURL(/\/settings$/);
  await page.goto('/settings/repositories/edit');
  await expect(page.getByTestId('author-hermes-bot@example.com')).toHaveCount(0);
});

// ISS-42316 (DES-37153): while a repository waits undecided the node holds one New repositories
// ask. Its row on Asks opens this page under Undecided, and deciding the last one there closes it.
test('the New repositories ask opens the page under Undecided and closes once none waits', async ({ page }) => {
  await page.goto('/asks');
  const row = page.getByTestId('ask-row').filter({ hasText: 'New repositories' });
  await expect(row).toHaveCount(1);
  await row.click();
  await expect(page).toHaveURL(/\/settings\/repositories\/edit\?status=undecided$/);
  await expect(page.getByRole('group', { name: 'Status' }).getByRole('button', { name: /^Undecided/ })).toHaveAttribute(
    'aria-pressed',
    'true'
  );
  await expect(page.getByTestId('repo-prototype')).toBeVisible();
  await expect(page.getByTestId('org-example-co')).toHaveCount(0);

  // Save takes acme-labs' recommended choice, which decides prototype and leaves none undecided.
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByRole('group', { name: 'Status' }).getByRole('button', { name: 'Undecided 0' })).toBeVisible();
  await page.goto('/asks');
  await expect(page.getByTestId('ask-row').filter({ hasText: 'New repositories' })).toHaveCount(0);
});

// The Undecided view (DES-37153, settings-repositories-undecided): where the New repositories ask
// opens the page. acme-labs is an organization a scan found after setup, never confirmed.
test.describe('the Undecided view', () => {
  const undecided = '/settings/repositories/edit?status=undecided';

  test('opens under Undecided, with a new organization on its recommended choice and each row its where-and-how line', async ({ page }) => {
    await page.goto(undecided);
    const chips = page.getByRole('group', { name: 'Status' });
    await expect(chips.getByRole('button', { name: /^Undecided/ })).toHaveAttribute('aria-pressed', 'true');
    await expect(page.getByTestId('org-example-co')).toHaveCount(0);

    const acme = page.getByTestId('org-acme-labs');
    await expect(acme.getByRole('radio')).toHaveCount(3);
    await expect(acme.getByLabel('All repositories in acme-labs, ask me about new ones · Recommended')).toBeChecked();
    await expect(acme.getByLabel('All repositories in acme-labs, new ones read automatically')).not.toBeChecked();
    await expect(acme.getByLabel('Chosen repositories')).not.toBeChecked();
    await expect(acme.getByTestId('found-prototype')).toHaveText(
      /^\S*\/demo\/prototype · new clone, [A-Z][a-z]{2} \d{1,2} note time · no commit of yours$/
    );
    // The organization's choice decides its rows, so they carry no select of their own.
    await expect(acme.getByLabel('Read prototype?')).toHaveCount(0);
  });

  test('Chosen repositories gives each row its select, opening on Read', async ({ page }) => {
    await page.goto(undecided);
    const acme = page.getByTestId('org-acme-labs');
    await acme.getByLabel('Chosen repositories').check();
    const select = acme.getByLabel('Read prototype?');
    await expect(select).toHaveValue('approved');
    await expect(select.getByRole('option')).toHaveText(['Read · Recommended', "Don't read", 'Undecided']);
  });

  test('Save with nothing changed takes the recommended choice and returns under the same chip', async ({ page }) => {
    await page.goto(undecided);
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page).toHaveURL(/\/settings\/repositories\/edit\?status=undecided$/);
    await expect(page.getByRole('group', { name: 'Status' }).getByRole('button', { name: 'Undecided 0' })).toBeVisible();
    await expect(page.getByTestId('org-acme-labs')).toHaveCount(0);

    await page.goto('/settings/repositories/edit');
    const acme = page.getByTestId('org-acme-labs');
    await expect(acme.getByLabel('All repositories in acme-labs')).toBeChecked();
    await expect(acme.getByLabel('Read new repositories automatically')).not.toBeChecked();
    await expect(acme.getByTestId('repo-prototype')).toContainText('Approved');
  });

  test("Don't read declines a row; Undecided leaves it waiting", async ({ page }) => {
    await page.goto(undecided);
    let acme = page.getByTestId('org-acme-labs');
    await acme.getByLabel('Chosen repositories').check();
    await acme.getByLabel('Read prototype?').selectOption({ label: 'Undecided' });
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page).toHaveURL(/\?status=undecided$/);

    // Left Undecided under Chosen, the organization is still one nobody confirmed: the page reads
    // again, back on its recommended choice.
    acme = page.getByTestId('org-acme-labs');
    await expect(acme.getByLabel('Read prototype?')).toHaveCount(0);
    await expect(acme.getByLabel('All repositories in acme-labs, ask me about new ones · Recommended')).toBeChecked();
    await acme.getByLabel('Chosen repositories').check();
    await acme.getByLabel('Read prototype?').selectOption({ label: "Don't read" });
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page.getByRole('group', { name: 'Status' }).getByRole('button', { name: 'Undecided 0' })).toBeVisible();

    await page.goto('/settings/repositories/edit');
    acme = page.getByTestId('org-acme-labs');
    await expect(acme.getByLabel('Chosen repositories')).toBeChecked();
    await expect(acme.getByTestId('repo-prototype')).toContainText('Declined');
  });
});
