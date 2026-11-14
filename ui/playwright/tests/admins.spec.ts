import { expect, test } from '../fixtures.ts';

// The admins' screens (DES-85466, design/digestif/admins.html): Members with Invite, the waiting
// approvals and the halt line; the invite composer; Promote to Admin and Remove as Admin on a member;
// and the approval items with the command to copy, the Signatures table and Decline. The node answers
// approvals from ISS-87806; until then these run against the mock node only.
const headers = { 'Digestif-Local': '1' };
test.beforeEach(async ({ request }) => {
  test.skip(process.env['DIGESTIF_NODE'] !== undefined, 'the node answers approvals from ISS-87806; the mock plays them');
  await request.post('/api/v0/_reset', { headers });
});

test('an admin sees Invite, each waiting approval with whom it waits on, and which members are admins', async ({ page }) => {
  await page.goto('/members');
  await expect(page.getByRole('link', { name: 'Invite' })).toBeVisible();
  const rows = page.getByTestId('approval-row');
  await expect(rows.filter({ hasText: 'Gil Hart' })).toContainText('Waiting on you · 2 of 3');
  await expect(rows.filter({ hasText: 'Dee Rao → admin' })).toContainText('Waiting on Dee · 0 of 4');
  await expect(page.getByTestId('member-row').filter({ hasText: 'Ada Park' })).toContainText('Ada Park (you) · admin');
  await expect(page.getByTestId('member-row').filter({ hasText: 'Fay Kim' })).not.toContainText('admin');
});

test('an invite is written as an email, every admin signs it with the command, and Decline ends it', async ({ page }) => {
  await page.goto('/members');
  await page.getByRole('link', { name: 'Invite' }).click();
  await expect(page).toHaveURL(/\/members\/invite$/);
  await page.getByLabel('To', { exact: true }).fill('Priya Raman <priya@raman.dev>');
  const body = page.getByLabel('Body');
  await expect(body).toHaveValue(/^Hi Priya,/);
  await expect(body).toHaveValue(/\{\{install_command\}\}/);
  await expect(body).toHaveValue(/until \{\{expires_at\}\}\./);
  await expect(page.getByLabel('Subject')).toHaveValue('Join our circle on Digestif');
  await page.getByLabel('Role').selectOption('admin');
  await page.getByRole('button', { name: 'Ask the admins' }).click();

  await expect(page).toHaveURL(/\/inbox\/itm-apv-/);
  await expect(page.getByRole('heading', { name: 'Invite Priya Raman' })).toBeVisible();
  await expect(page.getByTestId('item-subline')).toContainText('Waiting on you');
  await expect(page.getByTestId('command-text')).toHaveText(/^digestif-update approve apv-/);
  await expect(page.getByTestId('approval-facts')).toContainText('Priya Raman <priya@raman.dev>');
  await expect(page.getByTestId('approval-facts')).toContainText('Admin');
  await expect(page.getByTestId('approval-body')).toContainText('Hi Priya,');
  const signatures = page.getByTestId('signature-row');
  await expect(signatures).toHaveCount(3);
  await expect(signatures.filter({ hasText: 'Ada Park (you)' })).toContainText('Not yet');
  await expect(page.getByRole('button', { name: 'Acknowledge' })).toHaveCount(0);

  await page.getByRole('button', { name: 'Decline' }).click();
  await expect(page.getByTestId('item-subline')).toContainText('Declined');
  await expect(page.getByRole('button', { name: 'Decline' })).toHaveCount(0);
  await expect(page.getByTestId('command-block')).toHaveCount(0);
});

test('a promotion waits on the member before any admin signs', async ({ page }) => {
  await page.goto('/members');
  await page.getByTestId('approval-row').filter({ hasText: 'Dee Rao → admin' }).getByRole('link').first().click();
  await expect(page.getByRole('heading', { name: 'Promote Dee Rao to Admin' })).toBeVisible();
  await expect(page.getByTestId('item-subline')).toContainText('Waiting on Dee · 0 of 4');
  await expect(page.getByTestId('approval-added-key')).toHaveText('None yet');
  await expect(page.getByTestId('command-block')).toHaveCount(0);
});

test('an admin promotes a member from their page, and removes an admin while three keys sign', async ({ page }) => {
  await page.goto('/members');
  await page.getByRole('link', { name: 'Fay Kim' }).click();
  await expect(page.getByTestId('member-role')).toHaveText('Member');
  await expect(page.getByRole('button', { name: 'Mute' })).toBeVisible();
  await page.getByRole('button', { name: 'Promote to Admin' }).click();
  await expect(page.getByRole('heading', { name: 'Promote Fay Kim to Admin' })).toBeVisible();

  await page.goto('/members');
  await page.getByRole('link', { name: /^Ben Ortiz/ }).click();
  await expect(page.getByTestId('member-role')).toHaveText('Admin');
  await expect(page.getByRole('button', { name: 'Promote to Admin' })).toHaveCount(0);
  await page.getByRole('button', { name: 'Remove as Admin' }).click();
  await expect(page.getByRole('heading', { name: 'Remove Ben Ortiz as Admin' })).toBeVisible();
  await expect(page.getByTestId('command-text')).toHaveText(/^digestif-update approve apv-/);
});

test('a revoked key halts invites: Members names it and what lifts it, in place of Invite', async ({ page, request }) => {
  expect((await request.post('/api/v0/_revoke', { headers, data: { name: 'Cy' } })).status()).toBe(204);
  await page.goto('/members');
  await expect(page.getByTestId('invites-halted')).toContainText("Invites halted: Cy's key is revoked");
  await expect(page.getByRole('link', { name: 'Invite', exact: true })).toHaveCount(0);
  await page.getByRole('link', { name: 'Remove Cy as admin' }).click();
  await expect(page.getByRole('heading', { name: 'Cy Lund' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Promote to Admin' })).toHaveCount(0);
  await page.getByRole('button', { name: 'Remove as Admin' }).click();
  await page.goto('/members');
  await expect(page.getByTestId('invites-halted')).toContainText('Cy Lund → member: Waiting on 3 · 0 of 3');
});
