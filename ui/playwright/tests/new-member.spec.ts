// A new member, end to end (docs/design.md, The setup chat and the first note, A note is approved on its message,
// Approval and sending are two small jobs, Pause), against `digestif demo` reseeded as a member who
// has just joined. The member's agent is played by this file through the commands the agent and its
// behaviors run (`digestif setup ...`, `digestif note`, `digestif note checked`, `digestif learnings
// set`), and the member by the browser. The demo plays the app's send job before every request, as
// `digestif run` does on each pass. The mock node cannot run those commands, so this file runs only
// against the node (playwright/against-node.sh).
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';
import type { APIRequestContext, Page } from '@playwright/test';
import { chooseAction, headerActions } from '../actions.ts';
import { expect, test } from '../fixtures.ts';

const BIN = process.env['DIGESTIF_BIN'];
const HOME = process.env['DIGESTIF_DEMO_HOME'];
const LOCAL = { 'Digestif-Local': '1' };

test.skip(BIN === undefined || HOME === undefined, 'plays the agent through the digestif CLI against `digestif demo`');

/** One command the agent runs, against the demo node's directory and its plain-file keystore. */
function digestif(args: string[], input?: string): string {
  return execFileSync(BIN ?? '', [...args, '--data-dir', HOME ?? ''], {
    encoding: 'utf8',
    input: input ?? '',
    // SSH_CONNECTION gives the chat's no-browser lines: the suite opens the note page itself.
    env: { ...process.env, DIGESTIF_INSECURE_KEYSTORE_DIR: join(HOME ?? '', 'keys'), SSH_CONNECTION: 'digestif-demo' }
  });
}

interface Found {
  next?: string;
  names: { member_name?: string; agent_name?: string; digest_email?: string };
  sources: { id: string; label: string }[];
}

/** The setup chat, scripted: each proposal taken at its default, a rule, a deny entry, the brief and the Inbox step skipped. */
function setupChat(): string[] {
  const found = JSON.parse(digestif(['setup', 'found'])) as Found;
  expect(found.next).toBe('names');
  expect(found.sources.map((s) => s.label)).toEqual(['Claude Code sessions', 'Git repositories']);
  expect(
    digestif([
      'setup',
      'names',
      '--name',
      found.names.member_name ?? '',
      '--agent-name',
      found.names.agent_name ?? '',
      '--email',
      found.names.digest_email ?? 'ada@example.com'
    ])
  ).toContain('Saved.');
  expect(digestif(['setup', 'sources', '--all'])).toContain('Nothing was read from them until now.');
  expect(digestif(['setup', 'read'])).toContain('commit: Add a retry queue to the importer');
  expect(digestif(['setup', 'rule', '--text', 'Never mention customer names.'])).toContain(
    'Saved as a rule: Never mention customer names.'
  );
  expect(digestif(['setup', 'deny', '--kind', 'name', 'Acme'])).toContain('Added to your deny list: Acme.');
  expect(digestif(['setup', 'brief', '--text', 'I build developer tools for data teams.'])).toContain('Saved.');
  // The Inbox agent step is optional: the scripted member skips it, keeping the default prompt.
  expect((JSON.parse(digestif(['setup', 'found'])) as Found).next).toBe('inbox');
  expect(digestif(['setup', 'inbox', '--skip'])).toContain('Skipped.');
  expect((JSON.parse(digestif(['setup', 'found'])) as Found).next).toBe('first_note');
  return digestif(['setup', 'first-note']).trim().split('\n');
}

/**
 * The work run hands over a note its checks passed. The agent approves it itself when auto approval
 * is saved, which it reads after writing (docs/design.md, Approval and sending are two small jobs).
 */
async function agentWrites(request: APIRequestContext, text: string): Promise<string> {
  const approval = (await (await request.get('/api/v0/settings/approval', { headers: LOCAL })).json()) as { setting: string };
  const args = approval.setting === 'auto_approve' ? ['note', '--text', '-', '--approve'] : ['note', '--text', '-'];
  return digestif(args, text).trim();
}

/** The check behavior on a member's edit: both checks pass and remove nothing. */
function checksPass(version: string, text: string): void {
  digestif(['note', 'checked', version, '--text', '-'], text);
}

/** The agent's update of Learnings from the edit's diff. */
function learns(version: string, text: string): void {
  digestif(['learnings', 'set', version, '--text', '-'], text);
}

// The other files read the demo's Active member; leave it as they expect it.
test.afterEach(async ({ request }) => {
  await request.post('/api/v0/_reset', { headers: LOCAL });
});

const noteRow = (page: Page, preview: string) => page.getByTestId('feed-row').filter({ hasText: preview });

test('a new member: setup chat, the first note edited and approved, autonomy chosen, a pause and Unpause', async ({ page, request }) => {
  test.setTimeout(120_000);
  await request.post('/api/v0/_reset', { headers: LOCAL, data: { seed: 'new_member' } });

  await test.step('before the chat, the app says setup continues in the terminal, with no navigation', async () => {
    await page.goto('/');
    await expect(page.getByTestId('setup-continues')).toContainText('digestif setup');
    await expect(page.getByRole('navigation', { name: 'Sections' })).toHaveCount(0);
  });

  await test.step('the setup chat ends by starting the first note', async () => {
    const lastWords = setupChat();
    expect(lastWords[0]).toBe(
      'Setup is done. Your first note appears in Digestif once it is written, for you to approve before it goes to your circle.'
    );
    expect(lastWords.join('\n')).toContain('open --print');
    // The chat ran no join here, so no phrase was shown and the window can close at once (ISS-47892, ISS-48140).
    expect(lastWords.join('\n')).not.toContain('recovery phrase');
    expect(lastWords.join('\n')).toContain('You can close this window now');
    await page.goto('/');
    await expect(page).toHaveURL(/\/feed\/sha256/);
    await expect(page.getByTestId('note-progress')).toBeVisible();
    // Setup is done once the first note has started: the navigation opens (ISS-47299).
    await expect(page.getByRole('navigation', { name: 'Sections' })).toBeVisible();
  });

  let first = '';
  await test.step('the run hands the first note over, and its page shows it', async () => {
    const pageId = decodeURIComponent(new URL(page.url()).pathname.split('/').pop() ?? '');
    first = await agentWrites(request, 'Worked on: a retry queue for the importer.\nLearned: batching writes halves the lock time.');
    expect(first).toBe(pageId);
    await expect(page.getByTestId('note-text')).toContainText('Worked on: a retry queue for the importer.', { timeout: 10_000 });
  });

  await test.step('an edit with Save & approve goes out once its checks remove nothing', async () => {
    const edited = 'Worked on: a retry queue for the importer, capped at five tries.\nLearned: batching writes halves the lock time.';
    await chooseAction(page, 'Edit');
    await page.getByLabel('Note', { exact: true }).fill(edited);
    await page.getByRole('button', { name: 'Save & approve' }).click();
    await expect(page).toHaveURL(/\?version=/);
    await expect(page.getByTestId('checks-running')).toContainText('It goes out if they remove nothing.');
    await expect.poll(() => headerActions(page)).not.toContain('Approve');
    const version = decodeURIComponent(new URL(page.url()).searchParams.get('version') ?? '');
    checksPass(version, edited);
    learns(version, 'Say how a change is bounded: a retry queue names its cap.');
    await page.reload();
    await expect(page.getByTestId('note-status')).toContainText('Approved');
    // Sent, the note is its signed message.
    await expect(page.getByTestId('message-text')).toHaveText(edited);
    await expect.poll(() => headerActions(page)).not.toContain('Edit');
  });

  await test.step("the edit's Learnings, and the chat's rule and deny entry, are on Settings", async () => {
    await page.getByRole('link', { name: 'Settings', exact: true }).first().click();
    await expect(page.getByTestId('learnings-text')).toHaveText('Say how a change is bounded: a retry queue names its cap.');
    await expect(page.getByTestId('rules-text')).toContainText('Never mention customer names.');
    await expect(page.getByTestId('settings-deny')).toContainText('Acme');
    await expect(page.getByTestId('brief-text')).toHaveText('I build developer tools for data teams.');
    await expect(page.getByTestId('settings-approval')).toContainText('Every note waits for me');
  });

  await test.step('five notes approved with no change suggest auto approval', async () => {
    const days = ['the loader', 'the relay cursor', 'the invite email', 'the release checklist', 'the retry budget'];
    for (const what of days) {
      await agentWrites(request, 'Worked on: ' + what + '.');
      await page.goto('/feed');
      await expect(page.getByTestId('auto-approval-suggestion')).toHaveCount(0);
      await noteRow(page, what + '.')
        .first()
        .click();
      await chooseAction(page, 'Approve');
      await expect(page.getByTestId('note-status')).toContainText('Approved');
    }
    await page.goto('/feed');
    await expect(page.getByTestId('auto-approval-suggestion')).toContainText('Your last five notes were approved with no change.');
  });

  await test.step('Turn on opens Approval with Auto approve selected, and Save turns it on', async () => {
    await page.getByRole('link', { name: 'Turn on auto approval' }).click();
    await expect(page).toHaveURL(/\/settings\/approval\?setting=auto_approve$/);
    await expect(page.getByRole('radio', { name: 'Auto approve every note' })).toBeChecked();
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page).toHaveURL(/\/settings$/);
    await expect(page.getByTestId('settings-approval')).toContainText('Auto approve every note');
  });

  await test.step('the next note the agent writes is Auto approved', async () => {
    const id = await agentWrites(request, 'Worked on: the status note.');
    await page.goto('/feed');
    await expect(page.getByTestId('auto-approval-suggestion')).toHaveCount(0);
    await page.goto('/feed/' + encodeURIComponent(id));
    await expect(page.getByTestId('note-status')).toContainText('Auto approved');
  });

  await test.step('with Every note waits saved again, the next note waits', async () => {
    await page.goto('/settings');
    await page.getByTestId('settings-approval').getByRole('link', { name: 'Change' }).click();
    await page.getByRole('radio', { name: 'Every note waits for me' }).check();
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page.getByTestId('settings-approval')).toContainText('Every note waits for me');
    await agentWrites(request, 'Worked on: the Paused page.');
    await page.goto('/feed');
    await expect(noteRow(page, 'the Paused page.')).toContainText('Awaiting approval');
  });

  await test.step('Pause from Feed while a note waits: the whole app is the Paused page', async () => {
    await chooseAction(page, 'Pause');
    await expect(page).toHaveURL(/\/paused$/);
    const paragraph = page.getByTestId('paused-paragraph');
    await expect(paragraph).toContainText('Digestif is paused. You pressed Pause on');
    await expect(paragraph).toContainText('Unpause makes you Active right away, but it does not write a note on the spot.');
    await expect(paragraph).toContainText(/Your next note comes once your \w{3} \d{1,2} note goes out\./);
    await page.goto('/settings');
    await expect(page).toHaveURL(/\/paused$/);
  });

  await test.step('Unpause makes the member Active, and the waiting note is still there', async () => {
    await page.getByRole('button', { name: 'Unpause' }).click();
    await expect(page).toHaveURL(/\/feed$/);
    await expect.poll(() => headerActions(page)).toContain('Pause');
    await expect(noteRow(page, 'the Paused page.')).toContainText('Awaiting approval');
    await expect(noteRow(page, 'a retry queue for the importer, capped')).toHaveCount(1);
  });

  expect(first).toMatch(/^sha256:/);
});
