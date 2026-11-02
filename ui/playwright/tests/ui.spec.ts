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
  await page.goto('/settings/sources');
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

  test('Pause sends Paused at once, the whole app is the Paused page, and Unpause ends it', async ({ page }) => {
    await page.goto('/notes');
    await page.getByRole('button', { name: 'Pause' }).click();
    await expect(page).toHaveURL(/\/paused$/);
    const paragraph = page.getByTestId('paused-paragraph');
    await expect(paragraph).toContainText('Digestif is paused. You pressed Pause on');
    await expect(paragraph).toContainText('no notes are written while it stays paused');
    await expect(paragraph).toContainText('Unpause makes you Active right away, but it does not write a note on the spot.');
    // The demo's note waits, so the next note comes once it goes out.
    await expect(paragraph).toContainText(/Your next note comes once your \w{3} \d{1,2} note goes out\./);
    await expect(page.getByRole('navigation', { name: 'Sections' })).toHaveCount(0);

    // Nothing else opens while Paused.
    await page.goto('/feed');
    await expect(page).toHaveURL(/\/paused$/);

    await page.getByRole('button', { name: 'Unpause' }).click();
    await expect(page).toHaveURL(/\/notes$/);
    await expect(page.getByTestId('note-row').filter({ hasText: 'Waiting' })).toHaveCount(1);
    await expect(page.getByRole('button', { name: 'Pause' })).toBeVisible();
    await page.goto('/members');
    await expect(page.getByTestId('member-row').filter({ hasText: 'Ada Park' })).toContainText('Paused.');
  });

  test('a banner on every page three days before a pause, and the pause at 30 days', async ({ page, request }) => {
    test.skip(process.env['DIGESTIF_NODE'] !== undefined, "the mock's _note_age stands in for 27 days of waiting");
    const headers = { 'Digestif-Local': '1' };
    await request.post('/api/v0/_note_age', { headers, data: { id: 'n3', days: 27.5 } });
    for (const path of ['/feed', '/members']) {
      await page.goto(path);
      const banner = page.getByTestId('pause-warning');
      await expect(banner).toContainText(
        /Note has waited 27 days\. Digestif pauses on \w{3} \d{1,2} at \d{1,2}:\d{2} [AP]M unless it goes out\./
      );
    }
    await page.getByTestId('pause-warning').getByRole('link').click();
    await expect(page).toHaveURL(/\/notes\/n3$/);

    await request.post('/api/v0/_note_age', { headers, data: { id: 'n3', days: 31 } });
    await page.goto('/notes');
    await expect(page).toHaveURL(/\/paused$/);
    await expect(page.getByTestId('paused-paragraph')).toContainText('A note waited 30 days, so Digestif paused on');
  });

  test('a status note is one muted line in the Feed, never a card', async ({ page }) => {
    await page.goto('/feed');
    const line = page.getByTestId('feed-status-note').filter({ hasText: 'Cy Lund' });
    await expect(line).toContainText('Could not run today.');
    await expect(line.getByRole('link')).toHaveCount(0);
    await expect(page.getByRole('navigation', { name: 'Sections' })).not.toContainText('Dinners');
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
