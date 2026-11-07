import { createHash } from 'node:crypto';
import { expect, test } from '../fixtures.ts';

test.beforeEach(async ({ request }) => {
  await request.post('/api/v0/_reset', { headers: { 'Digestif-Local': '1' } });
});

test('while setup is open the app says it continues in the terminal, and the first note opens the app', async ({ page, request }) => {
  test.skip(process.env['DIGESTIF_NODE'] !== undefined, 'the demo member has shared a note; the mock plays a new one');
  const headers = { 'Digestif-Local': '1' };
  await page.goto('/');
  await expect(page).toHaveURL(/\/$/);
  await expect(page.getByTestId('setup-continues')).toContainText('digestif setup');
  await expect(page.getByTestId('command').getByRole('button', { name: 'Copy the command' })).toBeVisible();
  await expect(page.getByRole('navigation', { name: 'Sections' })).toHaveCount(0);

  // The setup chat starts the first note: setup is done, so the app opens on its message with the
  // navigation (ISS-47299).
  await request.post('/api/v0/_first_note', {
    headers,
    data: { progress: { state: 'writing', step: 'reading', sources: ['Git repositories'] } }
  });
  await page.goto('/');
  await expect(page).toHaveURL(/\/feed\/first$/);
  await expect(page.getByTestId('note-progress')).toContainText('Reading your sources');
  await expect(page.getByTestId('note-progress')).toContainText('Git repositories');
  await expect(page.getByRole('navigation', { name: 'Sections' })).toBeVisible();

  await request.post('/api/v0/_first_note', { headers, data: { progress: { state: 'no_activity', sources: [] } } });
  await page.reload();
  await expect(page.getByTestId('note-progress')).toContainText('No activity yet');
  await page.goto('/feed');
  await expect(page.locator('a[href="/feed/first"]')).toHaveCount(0);

  await request.post('/api/v0/_first_note', {
    headers,
    data: { progress: { state: 'failed', sources: [], message: 'Your agent is signed out.' } }
  });
  await page.goto('/notes/first');
  await expect(page).toHaveURL(/\/feed\/first$/);
  await expect(page.getByTestId('note-progress')).toContainText('Your agent is signed out.');

  // A run that ended before it finished (the node restarted under it) is not shown as reading.
  await request.post('/api/v0/_first_note', { headers, data: { progress: { state: 'stopped', sources: [] } } });
  await page.reload();
  await expect(page.getByTestId('note-progress')).toContainText('Nothing is writing your note right now');
  await page.getByRole('button', { name: 'Write it now' }).click();
  await expect(page.getByTestId('note-progress')).toContainText('Starting');

  // Once the run hands it over, the page is the note itself.
  await request.post('/api/v0/_first_note', { headers, data: { note: 'n3' } });
  await page.goto('/');
  await expect(page).toHaveURL(/\/feed\/n3$/);
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

  test('feed rows are links, and Post to the circle opens the form that posts as the person', async ({ page }) => {
    await page.goto('/feed');
    const rows = page.getByTestId('feed-row');
    await expect(rows.first()).toBeVisible();
    await expect(page.getByLabel('Write to the circle')).toHaveCount(0);
    await page.getByRole('link', { name: 'Post to the circle' }).click();
    await expect(page).toHaveURL(/\/feed\/new$/);
    await page.getByLabel('Write to the circle').fill('Hosting dinner 3 on the 20th.');
    await page.getByRole('button', { name: 'Post' }).click();
    await expect(page.getByTestId('message-text')).toHaveText('Hosting dinner 3 on the 20th.');
    await expect(page.getByText('written by the person')).toBeVisible();
    await page.getByRole('link', { name: 'Feed', exact: true }).first().click();
    await expect(rows.first()).toContainText('Hosting dinner 3 on the 20th.');
    await expect(rows.first()).toContainText('Ada Park');
  });

  test('Write a note now sits beside Post to the circle', async ({ page }) => {
    await page.goto('/feed');
    await page.getByRole('button', { name: 'Write a note now' }).click();
    await expect(page.getByTestId('writing-now')).toContainText('next pass');
    await expect(page.getByRole('button', { name: 'Write a note now' })).toBeDisabled();
  });

  test('an open problem is a line at the top of Feed', async ({ page, request }) => {
    test.skip(process.env['DIGESTIF_NODE'] !== undefined, "the mock's _problem stands in for a failed self-update");
    await request.post('/api/v0/_problem', { headers: { 'Digestif-Local': '1' }, data: { job: 'self_update', kind: 'failed' } });
    await page.goto('/feed');
    await expect(page.getByTestId('problem-line')).toContainText('Self-update failed since');
  });

  test('the Inbox is a section, and Notes is not', async ({ page }) => {
    test.skip(process.env['DIGESTIF_NODE'] !== undefined, 'the node keeps items from ISS-52609; the mock plays them');
    await page.goto('/inbox');
    await expect(page.getByRole('heading', { name: 'Inbox' })).toBeVisible();
    await expect(page.getByRole('navigation', { name: 'Sections' }).getByRole('link', { name: /Inbox/ })).toBeVisible();
    await expect(page.getByRole('navigation', { name: 'Sections' })).not.toContainText('Notes');
  });

  test('the theme toggle is an icon named for the mode it switches to', async ({ page }) => {
    await page.goto('/feed');
    const toggle = page.getByTestId('theme-toggle');
    const before = await toggle.getAttribute('aria-label');
    expect(before === 'Switch to dark mode' || before === 'Switch to light mode').toBe(true);
    await expect(toggle).not.toContainText(/Light|Dark/);
    await toggle.click();
    await expect(toggle).not.toHaveAttribute('aria-label', before ?? '');
  });

  test('a post the deny layer trips is refused and names the rule', async ({ page }) => {
    await page.goto('/feed/new');
    await page.getByLabel('Write to the circle').fill('notes at internal.example.com');
    await page.getByRole('button', { name: 'Post' }).click();
    await expect(page.getByRole('status')).toContainText('refused by deny: domain');
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

    // Removing it: the row opens the phone, whose Remove takes the phrase again.
    await page.getByTestId('phone-row').click();
    await page.getByRole('button', { name: 'Remove', exact: true }).click();
    const remove = page.getByTestId('phone-remove');
    await remove.getByLabel('Recovery phrase').fill('abandon art');
    await remove.getByRole('button', { name: 'Remove phone' }).click();
    await expect(page.getByText(/recovery phrase has 24 words, not 2/i)).toBeVisible();
    await remove.getByLabel('Recovery phrase').fill([...Array.from({ length: 23 }, () => 'abandon'), 'art'].join(' '));
    await remove.getByRole('button', { name: 'Remove phone' }).click();
    await expect(page.getByTestId('phone-remove')).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Remove', exact: true })).toHaveCount(0);
    await expect(page.locator('main dl')).toContainText('Removed');
    await page.getByRole('link', { name: 'Phones' }).click();
    await expect(page.getByTestId('phone-row')).toContainText('Removed');
  });

  test('names are changed on Settings with a new card', async ({ page }) => {
    await page.goto('/settings');
    await page.getByTestId('settings-names').getByRole('link', { name: 'Change' }).click();
    await expect(page).toHaveURL(/\/settings\/names$/);
    await expect(page.getByLabel('Your name')).toHaveValue('Ada Park');
    await page.getByLabel("Your agent's name").fill(' ');
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page.getByText('Name your agent.')).toBeVisible();
    await page.getByLabel('Your name').fill('Ada Lovelace');
    await page.getByLabel("Your agent's name").fill('Iris');
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page).toHaveURL(/\/settings$/);
    await expect(page.getByTestId('settings-names')).toContainText('Ada Lovelace');
    await expect(page.getByTestId('settings-names')).toContainText('Iris');
  });

  test('the agent check runs in the background and the agent is saved only once it passes', async ({ page }) => {
    await page.goto('/settings');
    await expect(page.getByTestId('settings-agent')).toContainText('None');
    await page.getByTestId('settings-agent').getByRole('link', { name: 'Change' }).click();
    await expect(page).toHaveURL(/\/settings\/agent$/);
    await page.getByLabel('Program').fill('no-such-agent-here');
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page.getByTestId('agent-error')).toHaveText('no-such-agent-here is not a program on this machine.');
    // The demo node runs the real check; the mock passes claude and fails a path naming signed-out.
    if (process.env['DIGESTIF_NODE'] !== undefined) return;
    await page.getByLabel('Program').fill('/opt/signed-out/claude');
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page.getByTestId('agent-check')).toHaveText('Checking Claude Code…');
    await expect(page.getByTestId('agent-error')).toContainText('Claude Code does not answer');
    await page.getByLabel('Program').fill('/usr/local/bin/claude');
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page.getByTestId('agent-check')).toHaveText('Checking Claude Code…');
    // Other pages answer while it runs, and nothing is saved until it passes.
    await page.getByRole('link', { name: 'Cancel' }).click();
    await expect(page).toHaveURL(/\/settings$/);
    await expect(page.getByTestId('settings-agent')).toContainText('None');
    await page.getByTestId('settings-agent').getByRole('link', { name: 'Change' }).click();
    await expect(page.getByTestId('agent-check')).toHaveText('Claude Code passed the check and is saved.');
    await page.getByRole('link', { name: 'Done' }).click();
    await expect(page).toHaveURL(/\/settings$/);
    await expect(page.getByTestId('settings-agent')).toContainText('Claude Code');
    await expect(page.getByTestId('settings-agent')).toContainText('/usr/local/bin/claude');
  });

  test('the Inbox agent reads under the default prompt until the member edits it, and Reset to default restores it', async ({ page }) => {
    test.skip(process.env['DIGESTIF_NODE'] !== undefined, 'the demo node runs the real agent check; the mock passes claude');
    const headers = { 'digestif-local': '1' };
    await page.request.put('/api/v0/settings/agent', { headers, data: { path: '/usr/local/bin/claude' } });
    await expect
      .poll(async () => ((await (await page.request.get('/api/v0/settings/agent/check', { headers })).json()) as { status: string }).status)
      .toBe('passed');
    await page.goto('/settings');
    await expect(page.getByTestId('settings-inbox-agent')).toContainText('The default prompt');
    await page.getByTestId('settings-inbox-agent').getByRole('link', { name: 'Change' }).click();
    await expect(page).toHaveURL(/\/settings\/inbox-agent$/);
    await expect(page.getByTestId('inbox-agent-origin')).toHaveText('The default');
    await expect(page.getByRole('button', { name: 'Reset to default' })).toBeDisabled();
    await page.getByRole('link', { name: 'Edit' }).click();
    await expect(page).toHaveURL(/\/settings\/inbox-agent\/edit$/);
    await page.getByLabel('Inbox prompt').fill('File work about Digestif with gh.');
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page).toHaveURL(/\/settings\/inbox-agent$/);
    await expect(page.getByTestId('inbox-agent-text')).toHaveText('File work about Digestif with gh.');
    await expect(page.getByTestId('inbox-agent-origin')).toContainText('from the default');
    await page.getByRole('button', { name: 'Reset to default' }).click();
    await expect(page.getByTestId('inbox-agent-origin')).toHaveText('The default');
    await expect(page.getByTestId('inbox-agent-text')).toContainText('Most messages need nothing from me.');
  });

  test('Pause sends Paused at once, the whole app is the Paused page, and Unpause ends it', async ({ page }) => {
    await page.goto('/feed');
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
    await expect(page).toHaveURL(/\/feed$/);
    await expect(page.getByTestId('feed-row').filter({ hasText: 'Awaiting approval' })).toHaveCount(1);
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
    await expect(page).toHaveURL(/\/feed\/n3$/);

    await request.post('/api/v0/_note_age', { headers, data: { id: 'n3', days: 31 } });
    await page.goto('/feed');
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
      'Agent',
      'Inbox agent',
      'Sources',
      'Repositories',
      'Brief',
      'Always on',
      'Rules',
      'Note prompt',
      'Learnings',
      'Deny list',
      'Approval',
      'Note time',
      'Digest',
      'Quiet hours',
      'Phones'
    ]);
    await expect(page.getByTestId('settings-names')).toContainText('Ada Park');
    for (const id of [
      'settings-names',
      'settings-agent',
      'settings-inbox-agent',
      'settings-sources',
      'settings-repositories',
      'settings-brief',
      'settings-rules',
      'settings-note-prompt',
      'settings-learnings',
      'settings-deny',
      'settings-approval',
      'settings-note-time',
      'settings-digest',
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

  test('a change to the note prompt is suggested with its judges, and withdrawn by its author', async ({ page }) => {
    await page.goto('/settings');
    await page.getByTestId('settings-note-prompt').getByRole('link', { name: 'Change' }).click();
    await expect(page.getByTestId('live-prompt-text')).toContainText('{{always_on_rules}}');
    await page.getByRole('link', { name: 'Suggest a change' }).click();
    await expect(page.getByLabel('Prompt', { exact: true })).toHaveValue(/\{\{always_on_rules\}\}/);
    await page.getByLabel('What it changes').fill('Name the next step');
    await page.getByLabel('Prompt', { exact: true }).fill('Write the note. Name the next step.');
    await page.getByLabel('Ben Ortiz').check();
    await page.getByRole('button', { name: 'Suggest' }).click();
    await expect(page.getByText('The prompt has to include {{always_on_rules}}')).toBeVisible();
    await page.getByLabel('Prompt', { exact: true }).fill('Write the note. Name the next step.\n{{always_on_rules}}');
    await page.getByRole('button', { name: 'Suggest' }).click();
    await expect(page.getByRole('heading', { name: 'Name the next step' })).toBeVisible();
    await expect(page.getByTestId('suggestion-judges')).toHaveText('Ada Park, Ben Ortiz');
    await page.getByRole('button', { name: 'Withdraw suggestion' }).click();
    await page.getByRole('button', { name: 'Withdraw', exact: true }).click();
    await expect(page).toHaveURL(/\/settings\/note-prompt$/);
    await expect(page.getByTestId('suggestion-row').filter({ hasText: 'Name the next step' })).toHaveCount(0);
    await expect(page.getByTestId('suggestion-row').filter({ hasText: 'Withdrawn suggestion' })).toHaveCount(1);
  });

  test('a note in two versions shows both unlabeled, and approving one is the pick', async ({ page, request }) => {
    test.skip(process.env['DIGESTIF_NODE'] !== undefined, "the mock's _note_pair stands in for a night judging a suggestion");
    await request.post('/api/v0/_note_pair', { headers: { 'Digestif-Local': '1' }, data: { id: 'n3' } });
    await page.goto('/feed/n3');
    await expect(page.getByTestId('pair-version')).toHaveCount(2);
    await expect(page.getByRole('button', { name: 'Approve', exact: true })).toHaveCount(0);
    await page.getByTestId('pair-version').first().getByRole('button', { name: 'Approve this one' }).click();
    await expect(page.getByTestId('pair-version')).toHaveCount(0);
    await page.goto('/settings/note-prompt');
    await page.getByTestId('suggestion-row').filter({ hasText: 'Keep Stuck on to one line' }).click();
    await expect(page.getByTestId('suggestion-round')).toContainText('Ada Park picked');
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

  test('the digest email is set on Settings, and an address is required', async ({ page }) => {
    await page.goto('/settings');
    await expect(page.getByTestId('settings-digest')).toContainText('None');
    await expect(page.getByTestId('settings-digest')).toContainText('7:00 AM');
    await page.getByTestId('settings-digest').getByRole('link', { name: 'Change' }).click();
    await expect(page).toHaveURL(/\/settings\/digest$/);
    await page.getByLabel('Email').fill('ada example.com');
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page.getByText('Enter an email address, such as you@example.com.')).toBeVisible();
    await page.getByLabel('Email').fill('ada@example.com');
    await page.getByLabel('After').selectOption('6');
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page).toHaveURL(/\/settings$/);
    await expect(page.getByTestId('settings-digest')).toContainText('ada@example.com');
    await expect(page.getByTestId('settings-digest')).toContainText('6:00 AM');
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

  test('a waiting note is approved on its message, and five unchanged approvals suggest auto approval', async ({ page }) => {
    await page.goto('/feed');
    await expect(page.getByTestId('auto-approval-suggestion')).toHaveCount(0);
    await page.getByTestId('feed-row').filter({ hasText: 'Awaiting approval' }).first().click();
    await expect(page.getByTestId('note-text')).toContainText('Worked on: the local web UI.');
    await expect(page.getByRole('list', { name: 'Versions' }).getByTestId('version-row')).toHaveCount(1);
    await page.getByRole('button', { name: 'Approve', exact: true }).click();
    await expect(page.getByRole('button', { name: 'Approve', exact: true })).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Edit' })).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Dismiss' })).toHaveCount(0);
    await page.getByRole('link', { name: 'Feed', exact: true }).first().click();
    await expect(page.getByTestId('auto-approval-suggestion')).toContainText('Your last five notes were approved with no change.');
    await expect(page.getByRole('link', { name: 'Turn on auto approval' })).toHaveAttribute(
      'href',
      '/settings/approval?setting=auto_approve'
    );
    await page.getByRole('button', { name: 'Not now' }).click();
    await expect(page.getByTestId('auto-approval-suggestion')).toHaveCount(0);
  });

  test('an edit makes a newer version, and nothing is approvable while its checks run', async ({ page }) => {
    await page.goto('/feed');
    await page.getByTestId('feed-row').filter({ hasText: 'Awaiting approval' }).first().click();
    await page.getByRole('button', { name: 'Edit' }).click();
    await expect(page.getByRole('button', { name: 'Save & approve' })).toBeVisible();
    await page.getByLabel('Note', { exact: true }).fill('Worked on: the local web UI and its tests.');
    await page.getByRole('button', { name: 'Save', exact: true }).click();
    await expect(page.getByTestId('checks-running')).toContainText('PII check running');
    await expect(page.getByRole('button', { name: 'Approve', exact: true })).toHaveCount(0);
    await expect(page.getByTestId('version-row')).toHaveCount(2);
    await expect(page.getByTestId('log-entry').filter({ hasText: 'You edited it' })).toHaveCount(1);
  });

  test('Dismiss discards a waiting note before approval, and an old note address opens its message', async ({ page }) => {
    await page.goto('/feed');
    await page.getByTestId('feed-row').filter({ hasText: 'Awaiting approval' }).first().click();
    await expect(page.getByRole('button', { name: 'Dismiss' })).toBeVisible();
    const at = new URL(page.url()).pathname.split('/').pop() ?? '';
    await page.goto('/notes/' + at);
    await expect(page).toHaveURL(new RegExp('/feed/' + at + '$'));
    await page.getByRole('button', { name: 'Dismiss' }).click();
    await expect(page).toHaveURL(/\/feed$/);
    await expect(page.getByTestId('feed-row').filter({ hasText: 'Awaiting approval' })).toHaveCount(0);
    await page.goto('/feed/' + at);
    await expect(page.getByTestId('note-status')).toContainText('Dismissed');
    await expect(page.getByTestId('log-entry').filter({ hasText: 'You dismissed it' })).toHaveCount(1);
    await expect(page.getByRole('button', { name: 'Approve', exact: true })).toHaveCount(0);
  });
});
