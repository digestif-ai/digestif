import { createHash } from 'node:crypto';
import { expect, test } from '@playwright/test';

test.beforeEach(async ({ request }) => {
  await request.post('/api/v0/_reset', { headers: { 'Digestif-Local': '1' } });
});

test('while setup is open the app is the first note, with no navigation', async ({ page, request }) => {
  test.skip(process.env['DIGESTIF_NODE'] !== undefined, 'the demo member has shared a note; the mock plays a new one');
  const headers = { 'Digestif-Local': '1' };
  await page.goto('/');
  await expect(page).toHaveURL(/\/notes\/first$/);
  await expect(page.getByTestId('first-note')).toContainText('digestif setup');
  await expect(page.getByRole('navigation', { name: 'Sections' })).toHaveCount(0);

  await request.post('/api/v0/_first_note', { headers, data: { state: 'writing', step: 'reading', sources: ['Git repositories'] } });
  await page.reload();
  await expect(page.getByTestId('first-note')).toContainText('Reading your sources');
  await expect(page.getByTestId('first-note')).toContainText('Git repositories');

  await request.post('/api/v0/_first_note', { headers, data: { state: 'no_activity' } });
  await page.reload();
  await expect(page.getByTestId('first-note')).toContainText('No activity yet');
  await expect(page.getByRole('navigation', { name: 'Sections' })).toBeVisible();

  // Once the first note waits, its page is the note page.
  await request.post('/api/v0/_first_note', { headers, data: { state: 'waiting', note: 'n3' } });
  await page.goto('/notes/first');
  await expect(page).toHaveURL(/\/notes\/n3$/);
  await expect(page.getByTestId('note-text')).toContainText('Worked on: the local web UI.');
});

test('a command source is added and removed on the edit page', async ({ page }) => {
  await page.goto('/sources/edit');
  await page.getByRole('button', { name: 'Add a command source' }).click();
  const form = page.getByRole('form', { name: 'Add a command source' });
  await form.getByLabel('Name').fill('Athena');
  await form.getByLabel('Program').fill('athena');
  await form.getByRole('button', { name: 'Add' }).click();
  await expect(form).toContainText('absolute path');
  await form.getByLabel('Program').fill('/bin/echo');
  await form.getByLabel('Arguments').fill('digestif: item opened');
  await form.getByRole('button', { name: 'Add' }).click();
  const row = page.getByTestId('source-command-athena');
  await expect(row).not.toBeChecked();
  await expect(page.getByText('/bin/echo digestif: item opened')).toBeVisible();
  await page.getByRole('button', { name: 'Remove' }).click();
  await expect(page.getByTestId('source-command-athena')).toHaveCount(0);
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

  test("members show each one's stage and last note, and a member can be muted", async ({ page }) => {
    await page.goto('/members');
    await expect(page.getByTestId('member-row').filter({ hasText: 'Dee Rao' })).toContainText('Paused');
    await expect(page.getByTestId('member-row').filter({ hasText: 'Dee Rao' })).toContainText('Paused.');
    await expect(page.getByTestId('member-row').filter({ hasText: 'Cy Lund' })).toContainText('Could not run today.');
    const fay = page.getByTestId('member-row').filter({ hasText: 'Fay Kim' });
    await expect(fay).toContainText('Onboarding');
    await expect(fay.getByTestId('member-agent')).toHaveText('');
    await expect(page.getByTestId('invitee-row')).toContainText('Eve Moss');
    await expect(page.getByTestId('invitee-row')).toContainText('Invited');
    await expect(page.getByTestId('invitee-row')).toContainText('Invite expires');
    await page.getByRole('link', { name: 'Ben Ortiz' }).click();
    await page.getByRole('button', { name: 'Mute' }).click();
    await expect(page.getByRole('button', { name: 'Unmute' })).toBeVisible();
    await expect(page.getByText('Muted: filtered before your agent reads them')).toBeVisible();
  });

  test("a phone is paired from the member's own page in three steps", async ({ page }) => {
    const keys = Buffer.alloc(64, 9);
    const code = 'p1.' + keys.toString('base64url') + '.' + createHash('sha256').update(keys).digest().subarray(0, 3).toString('base64url');
    await page.goto('/members');
    await page.getByRole('link', { name: 'Ada Park (you)' }).click();
    await expect(page.getByRole('list').filter({ hasText: 'device' }).getByRole('listitem')).toHaveCount(1);
    await page.getByRole('link', { name: 'Add a phone' }).click();
    await expect(page.getByRole('navigation', { name: 'Breadcrumb' })).toContainText('Ada Park');

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
    await expect(page.getByRole('heading', { name: 'Ada Park' })).toBeVisible();
    await expect(page.getByRole('list').filter({ hasText: 'device' }).getByRole('listitem')).toHaveCount(2);
  });

  test('a status note is one muted line in the Feed, never a card', async ({ page }) => {
    await page.goto('/feed');
    const line = page.getByTestId('feed-status-note').filter({ hasText: 'Cy Lund' });
    await expect(line).toContainText('Could not run today.');
    await expect(line.getByRole('link')).toHaveCount(0);
    await expect(page.getByRole('navigation', { name: 'Sections' })).not.toContainText('Dinners');
  });

  test('an empty brief offers a draft, which opens in the edit form and saves only when saved', async ({ page }) => {
    await page.goto('/brief');
    await page.getByRole('button', { name: 'Draft for me' }).click();
    await expect(page).toHaveURL(/\/brief\/edit$/);
    await expect(page.getByLabel('Brief')).toHaveValue(/I'm Ada Park\. I build developer tools/);
    await page.getByRole('link', { name: 'Cancel' }).click();
    await expect(page.getByRole('button', { name: 'Draft for me' })).toBeVisible();
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

  test('the always-on rule is on the rules page, with nothing to edit or remove', async ({ page }) => {
    await page.goto('/rules');
    const rule = page.getByTestId('always-on-rule');
    await expect(rule.getByRole('heading')).toHaveText('Absolute prohibition: financial institutions and instruments');
    await expect(rule).toContainText('This rule cannot be unlocked.');
    await expect(rule.getByRole('button')).toHaveCount(0);
    await expect(rule.getByRole('link')).toHaveCount(0);
  });

  test('quiet hours are set and cleared on the rules page', async ({ page }) => {
    await page.goto('/rules');
    await expect(page.getByTestId('quiet-hours')).toHaveText('None');
    await page.getByRole('link', { name: 'Edit quiet hours' }).click();
    await page.getByLabel('From', { exact: true }).fill('21:30');
    await page.getByLabel('To', { exact: true }).fill('06:45');
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page).toHaveURL(/\/rules$/);
    await expect(page.getByTestId('quiet-hours')).toContainText('21:30 to 06:45');
    await page.getByRole('link', { name: 'Edit quiet hours' }).click();
    await page.getByRole('button', { name: 'Clear' }).click();
    await expect(page).toHaveURL(/\/rules$/);
    await expect(page.getByTestId('quiet-hours')).toHaveText('None');
  });

  test('a waiting note is approved as it reads, and three unchanged approvals suggest auto approval', async ({ page }) => {
    await page.goto('/notes');
    await expect(page.getByTestId('auto-approval-suggestion')).toHaveCount(0);
    await page.getByTestId('note-row').filter({ hasText: 'Waiting' }).getByRole('link').first().click();
    await expect(page.getByTestId('note-text')).toContainText('Worked on: the local web UI.');
    await page.getByRole('button', { name: 'Approve', exact: true }).click();
    await expect(page.getByRole('button', { name: 'Approve', exact: true })).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Edit' })).toHaveCount(0);
    await page.getByRole('link', { name: 'Notes', exact: true }).first().click();
    await expect(page.getByTestId('auto-approval-suggestion')).toContainText('Your last three notes were approved with no change.');
    await expect(page.getByRole('link', { name: 'Turn on auto approval' })).toHaveAttribute(
      'href',
      '/settings/approval?setting=auto_approve'
    );
    await page.getByRole('button', { name: 'Not now' }).click();
    await expect(page.getByTestId('auto-approval-suggestion')).toHaveCount(0);
  });

  test('an edit makes a newer version, and nothing is approvable while its checks run', async ({ page }) => {
    await page.goto('/notes');
    await page.getByTestId('note-row').filter({ hasText: 'Waiting' }).getByRole('link').first().click();
    await page.getByRole('button', { name: 'Edit' }).click();
    await page.getByLabel('Note', { exact: true }).fill('Worked on: the local web UI and its tests.');
    await page.getByRole('button', { name: 'Save', exact: true }).click();
    await expect(page.getByTestId('checks-running')).toContainText('PII check running');
    await expect(page.getByRole('button', { name: 'Approve', exact: true })).toHaveCount(0);
    await page.getByRole('link', { name: 'Log' }).click();
    await expect(page.getByTestId('log-entry').filter({ hasText: 'You edited it' })).toHaveCount(1);
  });
});
