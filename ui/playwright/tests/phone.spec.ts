import { expect, test } from '../fixtures.ts';

// The phone web app against the mock mailing relay: the phone shows a pairing code, the laptop admits
// it (the mock's /v0/_pair stands in for the local UI's Add a phone), and the phone reads the
// choices and notices sealed to the member and answers them on its own chain.

// Every load of /app reads the relay and unseals what it holds (app/+layout.ts), so the first page a
// load shows waits on that read, which a loaded runner stretches past the default 5s.
const PHONE_READ = { timeout: 15_000 };
test.beforeEach(async ({ request }) => {
  await request.post('/v0/_reset');
});

test("a phone pairs, reads its node's join choice and picks on it", async ({ page, request }) => {
  await page.goto('/app');
  await expect(page.getByRole('heading', { name: 'Pair this phone' })).toBeVisible();
  const code = (await page.getByTestId('pairing-code').textContent()) ?? '';
  expect(code).toMatch(/^p1\.[A-Za-z0-9_-]{86}\.[A-Za-z0-9_-]{4}$/);

  expect((await request.post('/v0/_pair', { data: { code } })).status()).toBe(201);
  await expect(page.getByRole('heading', { name: 'Inbox' })).toBeVisible(PHONE_READ);

  // The keys stay on the phone: a reload reads the same pairing, not a new one.
  await page.reload();
  const join = page.getByTestId('item-row').filter({ hasText: 'Roman Cherkasov joined. Keep them in?' });
  await expect(join).toContainText('New', PHONE_READ);
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
  await expect(page.getByRole('heading', { name: 'Inbox' })).toBeVisible(PHONE_READ);

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
  await expect(page.getByRole('heading', { name: 'Inbox' })).toBeVisible(PHONE_READ);

  expect((await request.post('/v0/_paused')).status()).toBe(204);
  await page.reload();
  await expect(page.getByRole('heading', { name: 'Paused' })).toBeVisible(PHONE_READ);
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
  await expect(page.getByRole('heading', { name: 'Inbox' })).toBeVisible(PHONE_READ);

  expect((await request.post('/v0/_paused', { data: { by: 'node' } })).status()).toBe(204);
  await page.reload();
  await expect(page.getByRole('heading', { name: 'Paused' })).toBeVisible(PHONE_READ);
  await expect(page.getByTestId('paused-paragraph')).toContainText('Digestif is paused.');
  await expect(page.getByTestId('paused-phone-line')).toHaveText('Unpause can take up to a day to show here.');

  await page.getByRole('button', { name: 'Unpause' }).click();
  await expect(page.getByTestId('paused-phone-line')).toHaveText('Your machine unpauses when it next syncs, or when it wakes.');
  await expect(page.getByRole('button', { name: 'Unpause' })).toHaveCount(0);

  // The decision is on the phone's chain, so a reload still reads the choice as picked.
  await page.reload();
  await expect(page.getByTestId('paused-phone-line')).toHaveText('Your machine unpauses when it next syncs, or when it wakes.', PHONE_READ);
  await expect(page.getByRole('button', { name: 'Unpause' })).toHaveCount(0);
});

test("a phone answers another member's question sealed to her, and a circle question once the machine shares its deny list", async ({
  page,
  request
}) => {
  await page.goto('/app');
  const code = (await page.getByTestId('pairing-code').textContent()) ?? '';
  expect((await request.post('/v0/_pair', { data: { code } })).status()).toBe(201);
  await expect(page.getByRole('heading', { name: 'Inbox' })).toBeVisible(PHONE_READ);

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

  // The machine shares the member's deny list: the phone checks a circle answer as the machine does.
  expect((await request.post('/v0/_deny_list', { data: { entries: [{ kind: 'name', value: 'Zed Corp' }] } })).status()).toBe(204);
  await page.reload();
  await expect(page.getByLabel('Your answer')).toBeVisible(PHONE_READ);
  await page.getByLabel('Your answer').fill('Zed Corp has one.');
  await page.getByRole('button', { name: 'Answer' }).click();
  await expect(page.getByText('Refused before signing: deny: name.')).toBeVisible();
  held = (await (await request.get('/v0/_sealed_to_ada')).json()) as { answers: number; plain_answers: number };
  expect(held.plain_answers).toBe(0);
  await page.getByLabel('Your answer').fill('Ada, ask Roman: his harness has one.');
  await page.getByRole('button', { name: 'Answer' }).click();
  await expect(page.getByTestId('item-answer')).toContainText('Ada, ask Roman: his harness has one.');
  await expect(page.getByTestId('item-subline')).toContainText('Done');
  held = (await (await request.get('/v0/_sealed_to_ada')).json()) as { answers: number; plain_answers: number };
  expect(held.plain_answers).toBe(1);
});
