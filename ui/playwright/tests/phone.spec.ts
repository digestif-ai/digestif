import { expect, test } from '@playwright/test';

// The phone web app against the mock mailing relay: the phone shows a pairing code, the laptop admits
// it (the mock's /v0/_pair stands in for the local UI's Add a phone), and the phone reads the
// member's ask and answers it on its own chain.
test.beforeEach(async ({ request }) => {
  await request.post('/v0/_reset');
});

test('a phone pairs, reads an ask and answers it', async ({ page, request }) => {
  await page.goto('/app');
  await expect(page.getByRole('heading', { name: 'Pair this phone' })).toBeVisible();
  const code = (await page.getByTestId('pairing-code').textContent()) ?? '';
  expect(code).toMatch(/^p1\.[A-Za-z0-9_-]{86}\.[A-Za-z0-9_-]{4}$/);

  expect((await request.post('/v0/_pair', { data: { code } })).status()).toBe(201);
  await expect(page.getByRole('heading', { name: 'Asks' })).toBeVisible({ timeout: 15_000 });

  // The keys stay on the phone: a reload reads the same pairing, not a new one.
  await page.reload();
  await page.getByTestId('ask-row').filter({ hasText: 'Introduce Phong to Andrey?' }).click();
  await page.getByRole('button', { name: 'Make the intro' }).click();
  await expect(page.getByTestId('answer')).toHaveText('Make the intro');
  await page.getByRole('link', { name: 'Asks' }).click();
  await expect(page.getByRole('list', { name: 'Settled asks' })).toContainText('Make the intro');
  await expect(page.getByRole('list', { name: 'Open asks' })).toContainText('Nothing to answer');
});

test("while the member is Paused the phone shows the Paused page's words and no Unpause", async ({ page, request }) => {
  await page.goto('/app');
  const code = (await page.getByTestId('pairing-code').textContent()) ?? '';
  expect((await request.post('/v0/_pair', { data: { code } })).status()).toBe(201);
  await expect(page.getByRole('heading', { name: 'Asks' })).toBeVisible({ timeout: 15_000 });

  expect((await request.post('/v0/_paused')).status()).toBe(204);
  await page.reload();
  await expect(page.getByRole('heading', { name: 'Paused' })).toBeVisible();
  await expect(page.getByTestId('paused-paragraph')).toContainText('Digestif is paused.');
  await expect(page.getByTestId('paused-paragraph')).toContainText('Unpause makes you Active right away');
  await expect(page.getByText('Unpause can take up to a day to show here.')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Unpause' })).toHaveCount(0);
  await expect(page.getByTestId('ask-row')).toHaveCount(0);
});
