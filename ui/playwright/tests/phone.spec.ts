import { expect, test } from '../fixtures.ts';

// The phone web app against the mock mailing relay: the phone shows a pairing code, the laptop admits
// it (the mock's /v0/_pair stands in for the local UI's Add a phone), and the phone reads the
// choices and notices sealed to the member and answers them on its own chain.
test.beforeEach(async ({ request }) => {
  await request.post('/v0/_reset');
});

test("a phone pairs, reads its node's join choice and picks on it", async ({ page, request }) => {
  await page.goto('/app');
  await expect(page.getByRole('heading', { name: 'Pair this phone' })).toBeVisible();
  const code = (await page.getByTestId('pairing-code').textContent()) ?? '';
  expect(code).toMatch(/^p1\.[A-Za-z0-9_-]{86}\.[A-Za-z0-9_-]{4}$/);

  expect((await request.post('/v0/_pair', { data: { code } })).status()).toBe(201);
  await expect(page.getByRole('heading', { name: 'Inbox' })).toBeVisible({ timeout: 15_000 });

  // The keys stay on the phone: a reload reads the same pairing, not a new one.
  await page.reload();
  const join = page.getByTestId('item-row').filter({ hasText: 'Roman Cherkasov joined. Keep them in?' });
  await expect(join).toContainText('New');
  await join.click();
  await page.getByRole('button', { name: 'Remove them' }).click();
  await expect(page.getByTestId('answer')).toHaveText('Remove them');
  await expect(page.getByRole('button', { name: 'Keep them in' })).toHaveCount(0);
  await page.getByRole('link', { name: 'Inbox' }).click();
  await expect(page.getByTestId('item-row').filter({ hasText: 'Roman Cherkasov joined' })).toContainText('Done');
});

test("a phone acknowledges a notice and picks on another member's choice, sealed to its author", async ({ page, request }) => {
  await page.goto('/app');
  const code = (await page.getByTestId('pairing-code').textContent()) ?? '';
  expect((await request.post('/v0/_pair', { data: { code } })).status()).toBe(201);
  await expect(page.getByRole('heading', { name: 'Inbox' })).toBeVisible({ timeout: 15_000 });

  await page.getByTestId('item-row').filter({ hasText: 'Your note is ready' }).click();
  await page.getByRole('button', { name: 'Acknowledge' }).click();
  await expect(page.getByTestId('answer')).toHaveText('Acknowledged');
  await page.getByRole('link', { name: 'Inbox' }).click();
  await expect(page.getByTestId('item-row').filter({ hasText: 'Your note is ready' })).toContainText('Done');

  await page.getByTestId('item-row').filter({ hasText: "Install Ada's eval-harness behavior?" }).click();
  await page.getByRole('button', { name: 'Install' }).click();
  await expect(page.getByTestId('answer')).toHaveText('Install');
  const sealed = (await (await request.get('/v0/_sealed_to_ada')).json()) as { decisions: number };
  expect(sealed.decisions).toBe(1);
});

test("after Pause pressed, the phone shows the Paused page's words and no Unpause", async ({ page, request }) => {
  await page.goto('/app');
  const code = (await page.getByTestId('pairing-code').textContent()) ?? '';
  expect((await request.post('/v0/_pair', { data: { code } })).status()).toBe(201);
  await expect(page.getByRole('heading', { name: 'Inbox' })).toBeVisible({ timeout: 15_000 });

  expect((await request.post('/v0/_paused')).status()).toBe(204);
  await page.reload();
  await expect(page.getByRole('heading', { name: 'Paused' })).toBeVisible();
  await expect(page.getByTestId('paused-paragraph')).toContainText('Digestif is paused.');
  await expect(page.getByTestId('paused-paragraph')).toContainText('Unpause makes you Active right away');
  await expect(page.getByText('Unpause can take up to a day to show here.')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Unpause' })).toHaveCount(0);
  await expect(page.getByTestId('item-row')).toHaveCount(0);
});

test("after a pause the node made, the phone's Paused page answers the Paused choice with Unpause", async ({ page, request }) => {
  await page.goto('/app');
  const code = (await page.getByTestId('pairing-code').textContent()) ?? '';
  expect((await request.post('/v0/_pair', { data: { code } })).status()).toBe(201);
  await expect(page.getByRole('heading', { name: 'Inbox' })).toBeVisible({ timeout: 15_000 });

  expect((await request.post('/v0/_paused', { data: { by: 'node' } })).status()).toBe(204);
  await page.reload();
  await expect(page.getByRole('heading', { name: 'Paused' })).toBeVisible();
  await expect(page.getByTestId('paused-paragraph')).toContainText('Digestif is paused.');
  await expect(page.getByTestId('paused-phone-line')).toHaveText('Unpause can take up to a day to show here.');

  await page.getByRole('button', { name: 'Unpause' }).click();
  await expect(page.getByTestId('paused-phone-line')).toHaveText('Your machine unpauses when it next syncs, or when it wakes.');
  await expect(page.getByRole('button', { name: 'Unpause' })).toHaveCount(0);

  // The decision is on the phone's chain, so a reload still reads the choice as picked.
  await page.reload();
  await expect(page.getByTestId('paused-phone-line')).toHaveText('Your machine unpauses when it next syncs, or when it wakes.');
  await expect(page.getByRole('button', { name: 'Unpause' })).toHaveCount(0);
});

test("a phone answers another member's question sealed to her, and shows a circle question with no answer form", async ({
  page,
  request
}) => {
  await page.goto('/app');
  const code = (await page.getByTestId('pairing-code').textContent()) ?? '';
  expect((await request.post('/v0/_pair', { data: { code } })).status()).toBe(201);
  await expect(page.getByRole('heading', { name: 'Inbox' })).toBeVisible({ timeout: 15_000 });

  await page.getByTestId('item-row').filter({ hasText: 'Could you introduce me to Roman?' }).click();
  await expect(page.getByTestId('item-subline')).toContainText('Question');
  await expect(page.getByTestId('item-subline')).toContainText('from Ada Park');
  await page.getByLabel('Your answer').fill('Happy to, I will send a note tonight.');
  await page.getByRole('button', { name: 'Answer' }).click();
  await expect(page.getByTestId('item-answer')).toContainText('Happy to, I will send a note tonight.');
  await expect(page.getByTestId('item-answer')).toContainText('You');
  await expect(page.getByTestId('item-subline')).toContainText('Done');
  let held = (await (await request.get('/v0/_sealed_to_ada')).json()) as { answers: number; plain_answers: number };
  expect(held.answers).toBe(1);

  await page.getByRole('link', { name: 'Inbox' }).click();
  await page.getByTestId('item-row').filter({ hasText: 'Who has a good eval set for coding agents?' }).click();
  await expect(page.getByTestId('item-subline')).toContainText('to the circle');
  await expect(page.getByText('No answers yet')).toBeVisible();
  await expect(page.getByTestId('circle-answer-line')).toBeVisible();
  await expect(page.getByLabel('Your answer')).toHaveCount(0);
  held = (await (await request.get('/v0/_sealed_to_ada')).json()) as { answers: number; plain_answers: number };
  expect(held.plain_answers).toBe(0);
});
