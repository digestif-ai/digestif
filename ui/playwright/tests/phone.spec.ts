import { expect, test } from '../fixtures.ts';

// The phone web app against the mock mailing relay: the phone shows a pairing code, the laptop admits
// it (the mock's /v0/_pair stands in for the local UI's Add a phone), and the phone reads the
// node's own choice for the member and picks it on its own chain.
test.beforeEach(async ({ request }) => {
  await request.post('/v0/_reset');
});

test('a phone pairs, reads a choice and picks it', async ({ page, request }) => {
  await page.goto('/app');
  await expect(page.getByRole('heading', { name: 'Pair this phone' })).toBeVisible();
  const code = (await page.getByTestId('pairing-code').textContent()) ?? '';
  expect(code).toMatch(/^p1\.[A-Za-z0-9_-]{86}\.[A-Za-z0-9_-]{4}$/);

  expect((await request.post('/v0/_pair', { data: { code } })).status()).toBe(201);
  await expect(page.getByRole('heading', { name: 'Choices' })).toBeVisible({ timeout: 15_000 });

  // The keys stay on the phone: a reload reads the same pairing, not a new one.
  await page.reload();
  await page.getByTestId('choice-row').filter({ hasText: 'Let Phong join AI Dinner 2?' }).click();
  await page.getByRole('button', { name: 'Admit' }).click();
  await expect(page.getByTestId('picked')).toHaveText('Admit');
  await page.getByRole('link', { name: 'Choices' }).click();
  await expect(page.getByRole('list', { name: 'Settled choices' })).toContainText('Admit');
  await expect(page.getByRole('list', { name: 'Open choices' })).toContainText('Nothing to pick');
});

test("after Pause pressed, the phone shows the Paused page's words and no Unpause", async ({ page, request }) => {
  await page.goto('/app');
  const code = (await page.getByTestId('pairing-code').textContent()) ?? '';
  expect((await request.post('/v0/_pair', { data: { code } })).status()).toBe(201);
  await expect(page.getByRole('heading', { name: 'Choices' })).toBeVisible({ timeout: 15_000 });

  expect((await request.post('/v0/_paused')).status()).toBe(204);
  await page.reload();
  await expect(page.getByRole('heading', { name: 'Paused' })).toBeVisible();
  await expect(page.getByTestId('paused-paragraph')).toContainText('Digestif is paused.');
  await expect(page.getByTestId('paused-paragraph')).toContainText('Unpause makes you Active right away');
  await expect(page.getByText('Unpause can take up to a day to show here.')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Unpause' })).toHaveCount(0);
  await expect(page.getByTestId('choice-row')).toHaveCount(0);
});

test("after a pause the node made, the phone's Paused page picks Unpause on the Paused choice", async ({ page, request }) => {
  await page.goto('/app');
  const code = (await page.getByTestId('pairing-code').textContent()) ?? '';
  expect((await request.post('/v0/_pair', { data: { code } })).status()).toBe(201);
  await expect(page.getByRole('heading', { name: 'Choices' })).toBeVisible({ timeout: 15_000 });

  expect((await request.post('/v0/_paused', { data: { by: 'node' } })).status()).toBe(204);
  await page.reload();
  await expect(page.getByRole('heading', { name: 'Paused' })).toBeVisible();
  await expect(page.getByTestId('paused-paragraph')).toContainText('Digestif is paused.');
  await expect(page.getByTestId('paused-phone-line')).toHaveText('Unpause can take up to a day to show here.');

  await page.getByRole('button', { name: 'Unpause' }).click();
  await expect(page.getByTestId('paused-phone-line')).toHaveText('Your machine unpauses when it next syncs, or when it wakes.');
  await expect(page.getByRole('button', { name: 'Unpause' })).toHaveCount(0);

  // The pick is on the phone's chain, so a reload still reads the choice as picked.
  await page.reload();
  await expect(page.getByTestId('paused-phone-line')).toHaveText('Your machine unpauses when it next syncs, or when it wakes.');
  await expect(page.getByRole('button', { name: 'Unpause' })).toHaveCount(0);
});
