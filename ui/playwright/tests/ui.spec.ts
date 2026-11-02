import { createHash } from 'node:crypto';
import { expect, test } from '@playwright/test';

test.beforeEach(async ({ request }) => {
  await request.post('/api/v0/_reset', { headers: { 'Digestif-Local': '1' } });
});

test('first run is a source picker with nothing selected and a first-note preview', async ({ page }) => {
  await page.goto('/');
  await expect(page).toHaveURL(/\/settings\/sources$/);
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
  await page.getByRole('link', { name: 'Settings', exact: true }).click();
  await expect(page.getByRole('list', { name: 'Chosen sources' })).toContainText('Git repositories');
});

test('a command source is added, previewed and removed on the edit page', async ({ page }) => {
  await page.goto('/settings/sources');
  await page.getByRole('button', { name: 'Add a command source' }).click();
  const form = page.getByRole('form', { name: 'Add a command source' });
  await form.getByLabel('Name').fill('Athena');
  await form.getByLabel('Program').fill('athena');
  await form.getByRole('button', { name: 'Add' }).click();
  await expect(form).toContainText('absolute path');
  // A program every machine has, so the node (which runs it) previews what the mock makes up.
  await form.getByLabel('Program').fill('/bin/echo');
  await form.getByLabel('Arguments').fill('digestif: item opened');
  await form.getByRole('button', { name: 'Add' }).click();
  const row = page.getByTestId('source-command-athena');
  await expect(row).not.toBeChecked();
  await expect(page.getByText('/bin/echo digestif: item opened')).toBeVisible();
  await row.check();
  await page.getByRole('button', { name: 'Preview' }).click();
  await expect(page.getByTestId('preview')).toContainText('Athena: digestif: item opened');
  await page.getByRole('button', { name: 'Remove' }).click();
  await expect(page.getByTestId('source-command-athena')).toHaveCount(0);
});

test('joining with no sources is one click', async ({ page }) => {
  await page.goto('/settings/sources');
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

  test('a phone is paired from Settings in three steps', async ({ page }) => {
    const keys = Buffer.alloc(64, 9);
    const code = 'p1.' + keys.toString('base64url') + '.' + createHash('sha256').update(keys).digest().subarray(0, 3).toString('base64url');
    await page.goto('/settings');
    await expect(page.getByTestId('settings-phones')).toContainText('None');
    await page.getByTestId('settings-phones').getByRole('link', { name: 'Change' }).click();
    await expect(page.getByTestId('phone-row')).toHaveCount(0);
    await page.getByRole('link', { name: 'Add a phone' }).click();
    await expect(page.getByRole('navigation', { name: 'Breadcrumb' })).toContainText('Phones');

    // Step 1: the mailing relay's phone app, as a link and a QR code.
    const step1 = page.getByTestId('phone-step-1');
    await expect(step1.getByRole('link', { name: 'https://relay-1.example/app/' })).toHaveAttribute('href', 'https://relay-1.example/app/');
    await expect(step1.getByRole('img', { name: 'QR code for the phone app' })).toBeVisible();

    // Step 2: the code is checked as it is typed.
    await page.getByLabel('Pairing code').fill('hello');
    await expect(page.getByTestId('code-check')).toHaveText('Not a pairing code: it starts with p1. and comes from the phone.');
    await page.getByLabel('Pairing code').fill(code.slice(0, -1) + (code.endsWith('A') ? 'B' : 'A'));
    await expect(page.getByTestId('code-check')).toHaveText("The pairing code's check does not match; retype it.");
    await page.getByLabel('Pairing code').fill(code);
    await expect(page.getByTestId('code-check')).toHaveText('The code checks out.');

    // Step 3: the phrase signs the admission. Ada's phrase in the demo node (node/web/demo.ml); the
    // mock checks only its word count.
    await page.getByLabel('Recovery phrase').fill('abandon art');
    await page.getByRole('button', { name: 'Add phone' }).click();
    await expect(page.getByText(/recovery phrase has 24 words, not 2/i)).toBeVisible();
    await page.getByLabel('Recovery phrase').fill([...Array.from({ length: 23 }, () => 'abandon'), 'art'].join(' '));
    await page.getByRole('button', { name: 'Add phone' }).click();
    await expect(page.getByRole('status')).toHaveText('Phone added. It finishes setting itself up on its next sync.');
    await page.getByRole('link', { name: 'Done' }).click();
    await expect(page.getByRole('heading', { name: 'Phones' })).toBeVisible();
    await expect(page.getByTestId('phone-row')).toHaveCount(1);
  });

  test('a dinner lists its guests', async ({ page }) => {
    await page.goto('/dinners');
    await page.getByTestId('dinner-row').first().click();
    await expect(page.getByRole('list', { name: 'Guests' })).toContainText('Eve Moss');
    await expect(page.getByRole('list', { name: 'Guests' })).toContainText('Invited');
  });

  test('Settings is one page, its sections in order, each with Change but the always-on rule', async ({ page }) => {
    await page.goto('/feed');
    const nav = page.getByRole('navigation', { name: 'Sections' });
    await expect(nav.getByRole('link', { name: 'Settings', exact: true })).toBeVisible();
    for (const gone of ['Sources', 'Rules', 'My brief']) await expect(nav.getByRole('link', { name: gone, exact: true })).toHaveCount(0);
    await nav.getByRole('link', { name: 'Settings', exact: true }).click();
    await expect(page).toHaveURL(/\/settings$/);
    const titles = await page.locator('main section > div > h2').allTextContents();
    expect(titles).toEqual([
      'Names',
      'Sources',
      'Brief',
      'Always on',
      'Rules',
      'Learnings',
      'Deny list',
      'Approval',
      'Note time',
      'Quiet hours',
      'Phones'
    ]);
    await expect(page.getByTestId('settings-names')).toContainText('Ada Park');
    for (const id of [
      'settings-sources',
      'settings-brief',
      'settings-rules',
      'settings-learnings',
      'settings-deny',
      'settings-approval',
      'settings-note-time',
      'quiet-hours',
      'settings-phones'
    ])
      await expect(page.getByTestId(id).getByRole('link', { name: 'Change' })).toBeVisible();
  });

  test('an empty brief offers a draft on its edit page, which saves only when saved', async ({ page }) => {
    await page.goto('/settings');
    await page.getByTestId('settings-brief').getByRole('link', { name: 'Change' }).click();
    await expect(page).toHaveURL(/\/settings\/brief$/);
    await page.getByRole('button', { name: 'Draft for me' }).click();
    await expect(page.getByLabel('Brief')).toHaveValue(/I'm Ada Park\. I build developer tools/);
    await page.getByRole('link', { name: 'Cancel' }).click();
    await expect(page.getByTestId('settings-brief')).toContainText('None');
  });

  test('the brief is read on Settings and edited on its own page', async ({ page }) => {
    await page.goto('/settings/brief');
    await page.getByLabel('Brief').fill('I build developer tools.');
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page).toHaveURL(/\/settings$/);
    await expect(page.getByTestId('brief-text')).toHaveText('I build developer tools.');
  });

  test('deny entries are added on the deny list page and removed on their own', async ({ page }) => {
    await page.goto('/settings');
    await page.getByTestId('settings-deny').getByRole('link', { name: 'Change' }).click();
    await page.getByRole('button', { name: 'Add' }).click();
    await page.getByLabel('Kind').selectOption('name');
    await page.getByLabel('Value').fill('Acme Corp');
    await page.getByRole('button', { name: 'Save' }).click();
    await page.getByTestId('deny-row').filter({ hasText: 'Acme Corp' }).click();
    await page.getByRole('button', { name: 'Remove from deny list' }).click();
    await page.getByRole('button', { name: 'Remove', exact: true }).click();
    await expect(page).toHaveURL(/\/settings\/deny$/);
    await expect(page.getByTestId('deny-row').filter({ hasText: 'Acme Corp' })).toHaveCount(0);
  });

  test('the always-on rule is on Settings, with nothing to edit or remove', async ({ page }) => {
    await page.goto('/settings');
    const rule = page.getByTestId('always-on-rule');
    await expect(rule.getByRole('heading', { level: 3 })).toHaveText('Absolute prohibition: financial institutions and instruments');
    await expect(rule).toContainText('This rule cannot be unlocked.');
    await expect(rule.getByRole('button')).toHaveCount(0);
    await expect(rule.getByRole('link')).toHaveCount(0);
  });

  test('note time takes any time of day and shows on Settings', async ({ page }) => {
    await page.goto('/settings');
    await expect(page.getByTestId('settings-note-time')).toContainText('7:00 AM');
    await page.getByTestId('settings-note-time').getByRole('link', { name: 'Change' }).click();
    await expect(page).toHaveURL(/\/settings\/note-time$/);
    await page.getByLabel('Note time').fill('13:15');
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page).toHaveURL(/\/settings$/);
    await expect(page.getByTestId('settings-note-time')).toContainText('1:15 PM');
  });

  test('quiet hours are set and cleared from Settings', async ({ page }) => {
    await page.goto('/settings');
    await expect(page.getByTestId('quiet-hours')).toContainText('None');
    await page.getByTestId('quiet-hours').getByRole('link', { name: 'Change' }).click();
    await page.getByLabel('From', { exact: true }).fill('21:30');
    await page.getByLabel('To', { exact: true }).fill('06:45');
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page).toHaveURL(/\/settings$/);
    await expect(page.getByTestId('quiet-hours')).toContainText('21:30 to 06:45');
    await page.getByTestId('quiet-hours').getByRole('link', { name: 'Change' }).click();
    await page.getByRole('button', { name: 'Clear' }).click();
    await expect(page).toHaveURL(/\/settings$/);
    await expect(page.getByTestId('quiet-hours')).toContainText('None');
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

  test('a nightly run that failed on every try says why beside Write a note now', async ({ page, request }) => {
    test.skip(process.env['DIGESTIF_NODE'] !== undefined, 'digestif demo records no nightly run; node/web/test covers the API');
    await request.put('/api/v0/sources', { data: { selected: ['git'] }, headers: { 'Digestif-Local': '1' } });
    await page.goto('/approvals');
    await expect(page.getByTestId('nightly-failure')).toHaveText(
      'No note 5h ago. The nightly note failed 3 times; the last try: the writer wrote nothing for 5 minutes of awake time'
    );
    await page.getByRole('button', { name: 'Write a note now' }).click();
    await expect(page.getByTestId('nightly-failure')).toHaveCount(0);
  });

  test('a member asks for a note now instead of waiting for the night', async ({ page, request }) => {
    await request.put('/api/v0/sources', { data: { selected: ['git'] }, headers: { 'Digestif-Local': '1' } });
    await page.goto('/approvals');
    await page.getByRole('button', { name: 'Write a note now' }).click();
    await expect(page.getByTestId('write-note-requested')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Write a note now' })).toBeDisabled();
  });
});
