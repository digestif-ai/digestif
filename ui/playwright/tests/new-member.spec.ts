// A new member, end to end (docs/design.md, The setup chat and the first note, Approve and Edit,
// Approval and sending are two small jobs, Pause), against `digestif demo` reseeded as a member who
// has just joined. The member's agent is played by this file through the commands the agent and its
// behaviors run (`digestif setup ...`, `digestif note`, `digestif note checked`, `digestif learnings
// set`), and the member by the browser. The demo plays the app's send job before every request, as
// `digestif run` does on each pass. The mock node cannot run those commands, so this file runs only
// against the node (playwright/against-node.sh).
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';
import { expect, test, type APIRequestContext, type Page } from '@playwright/test';

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
  names: { member_name?: string; agent_name?: string };
  sources: { id: string; label: string }[];
}

/** The setup chat, scripted: each proposal taken at its default, a rule, a deny entry and the brief. */
function setupChat(): string[] {
  const found = JSON.parse(digestif(['setup', 'found'])) as Found;
  expect(found.next).toBe('names');
  expect(found.sources.map((s) => s.label)).toEqual(['Claude Code sessions', 'Git repositories']);
  expect(digestif(['setup', 'names', '--name', found.names.member_name ?? '', '--agent-name', found.names.agent_name ?? ''])).toContain(
    'Saved.'
  );
  expect(digestif(['setup', 'sources', '--all'])).toContain('Nothing was read from them until now.');
  expect(digestif(['setup', 'read'])).toContain('commit: Add a retry queue to the importer');
  expect(digestif(['setup', 'rule', '--text', 'Never mention customer names.'])).toContain(
    'Saved as a rule: Never mention customer names.'
  );
  expect(digestif(['setup', 'deny', '--kind', 'name', 'Acme'])).toContain('Added to your deny list: Acme.');
  expect(digestif(['setup', 'brief', '--text', 'I build developer tools for data teams.'])).toContain('Saved.');
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

const noteRow = (page: Page, preview: string) => page.getByTestId('note-row').filter({ hasText: preview });

test('a new member: setup chat, the first note edited and approved, autonomy chosen, a pause and Unpause', async ({ page, request }) => {
  test.setTimeout(120_000);
  await request.post('/api/v0/_reset', { headers: LOCAL, data: { seed: 'new_member' } });

  await test.step('before the chat, the app is the first note page, with no navigation', async () => {
    await page.goto('/');
    await expect(page).toHaveURL(/\/notes\/first$/);
    await expect(page.getByTestId('first-note')).toContainText('digestif setup');
    await expect(page.getByRole('navigation', { name: 'Sections' })).toHaveCount(0);
  });

  await test.step('the setup chat ends by starting the first note', async () => {
    const lastWords = setupChat();
    expect(lastWords[0]).toBe("I'm writing your first note now, from your recent work. Setup is done when it is approved.");
    expect(lastWords.join('\n')).toContain('open --print');
    expect(lastWords.join('\n')).toContain('Your recovery phrase is still in this window');
    await page.reload();
    await expect(page.getByTestId('first-note')).toContainText('Setup is done when this note is approved.');
  });

  let first = '';
  await test.step('the first note waits, and its page becomes the note', async () => {
    first = await agentWrites(request, 'Worked on: a retry queue for the importer.\nLearned: batching writes halves the lock time.');
    await expect(page).toHaveURL(/\/notes\/sha256/, { timeout: 10_000 });
    await expect(page.getByTestId('note-text')).toContainText('Worked on: a retry queue for the importer.');
    await expect(page.getByRole('navigation', { name: 'Sections' })).toHaveCount(0);
  });

  await test.step('an edit with Save & approve goes out once its checks remove nothing', async () => {
    const edited = 'Worked on: a retry queue for the importer, capped at five tries.\nLearned: batching writes halves the lock time.';
    await page.getByRole('button', { name: 'Edit' }).click();
    await page.getByLabel('Note', { exact: true }).fill(edited);
    await page.getByRole('button', { name: 'Save & approve' }).click();
    await expect(page).toHaveURL(/\?version=/);
    await expect(page.getByTestId('checks-running')).toContainText('It goes out if they remove nothing.');
    await expect(page.getByRole('button', { name: 'Approve', exact: true })).toHaveCount(0);
    const version = decodeURIComponent(new URL(page.url()).searchParams.get('version') ?? '');
    checksPass(version, edited);
    learns(version, 'Say how a change is bounded: a retry queue names its cap.');
    await page.reload();
    await expect(page.getByTestId('note-status')).toContainText('Approved');
    await expect(page.getByTestId('note-text')).toHaveText(edited);
    await expect(page.getByRole('button', { name: 'Edit' })).toHaveCount(0);
    // Setup is done: the first note went out, and the navigation opens.
    await expect(page.getByRole('navigation', { name: 'Sections' })).toBeVisible();
  });

  await test.step("the edit's Learnings, and the chat's rule and deny entry, are on Settings", async () => {
    await page.getByRole('link', { name: 'Settings', exact: true }).first().click();
    await expect(page.getByTestId('learnings-text')).toHaveText('Say how a change is bounded: a retry queue names its cap.');
    await expect(page.getByTestId('rules-text')).toContainText('Never mention customer names.');
    await expect(page.getByTestId('settings-deny')).toContainText('Acme');
    await expect(page.getByTestId('brief-text')).toHaveText('I build developer tools for data teams.');
    await expect(page.getByTestId('settings-approval')).toContainText('Every note waits for me');
  });

  await test.step('three notes approved with no change suggest auto approval', async () => {
    const days = ['the loader', 'the relay cursor', 'the invite email'];
    for (const what of days) {
      await agentWrites(request, 'Worked on: ' + what + '.');
      await page.goto('/notes');
      await expect(page.getByTestId('auto-approval-suggestion')).toHaveCount(0);
      await noteRow(page, 'Worked on: ' + what + '.')
        .getByRole('link')
        .first()
        .click();
      await page.getByRole('button', { name: 'Approve', exact: true }).click();
      await expect(page.getByTestId('note-status')).toContainText('Approved');
    }
    await page.goto('/notes');
    await expect(page.getByTestId('auto-approval-suggestion')).toContainText('Your last three notes were approved with no change.');
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
    await agentWrites(request, 'Worked on: the status note.');
    await page.goto('/notes');
    await expect(page.getByTestId('auto-approval-suggestion')).toHaveCount(0);
    await expect(noteRow(page, 'Worked on: the status note.')).toContainText('Auto approved');
  });

  await test.step('with Every note waits saved again, the next note waits', async () => {
    await page.goto('/settings');
    await page.getByTestId('settings-approval').getByRole('link', { name: 'Change' }).click();
    await page.getByRole('radio', { name: 'Every note waits for me' }).check();
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page.getByTestId('settings-approval')).toContainText('Every note waits for me');
    await agentWrites(request, 'Worked on: the Paused page.');
    await page.goto('/notes');
    await expect(noteRow(page, 'Worked on: the Paused page.')).toContainText('Waiting');
  });

  await test.step('Pause from Notes while a note waits: the whole app is the Paused page', async () => {
    await page.getByRole('button', { name: 'Pause' }).click();
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
    await expect(page).toHaveURL(/\/notes$/);
    await expect(page.getByRole('button', { name: 'Pause' })).toBeVisible();
    await expect(noteRow(page, 'Worked on: the Paused page.')).toContainText('Waiting');
    await expect(noteRow(page, 'Worked on: a retry queue for the importer, capped')).toContainText('Approved');
  });

  expect(first).toMatch(/^sha256:/);
});
