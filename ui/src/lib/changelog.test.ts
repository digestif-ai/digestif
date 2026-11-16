import { describe, expect, it } from 'vitest';
import { compareVersions, readChangelog, shownVersions, type Changelog } from './changelog.ts';

const log: Changelog = {
  versions: [
    { version: '0.1.9', entries: [{ summary: 'Older', category: 'fix' }] },
    { version: '0.1.11', entries: [{ summary: 'Newest', category: 'feature' }] },
    { version: '0.1.10', entries: [{ summary: 'The Inbox reads like Gmail', category: 'improvement' }] }
  ]
};

describe('the changelog (DIG-128)', () => {
  it('orders versions by number, not by text', () => {
    expect(compareVersions('0.1.10', '0.1.9')).toBeGreaterThan(0);
    expect(compareVersions('1.0.0', '0.9.9')).toBeGreaterThan(0);
    expect(compareVersions('0.1.0', '0.1.0')).toBe(0);
  });

  it('shows the running version and every one before it, newest first', () => {
    expect(shownVersions(log, '0.1.10').map((v) => v.version)).toEqual(['0.1.10', '0.1.9']);
  });

  it('shows every version for a build that is no release', () => {
    expect(shownVersions(log, '0.0.0').map((v) => v.version)).toEqual(['0.1.11', '0.1.10', '0.1.9']);
    expect(shownVersions(log, undefined).map((v) => v.version)).toEqual(['0.1.11', '0.1.10', '0.1.9']);
  });

  it('reads the file the build carries, leaving out what it cannot read', async () => {
    const body = {
      versions: [{ version: '0.1.10', entries: [{ summary: 'Kept', category: 'fix' }, { category: 'fix' }] }, { entries: [] }]
    };
    const fetcher = (() => Promise.resolve(new Response(JSON.stringify(body)))) as unknown as typeof fetch;
    expect(await readChangelog(fetcher)).toEqual({
      versions: [{ version: '0.1.10', released_at: undefined, entries: [{ summary: 'Kept', category: 'fix' }] }]
    });
  });

  it('names a file that did not load', async () => {
    const fetcher = (() => Promise.resolve(new Response('', { status: 404 }))) as unknown as typeof fetch;
    await expect(readChangelog(fetcher)).rejects.toThrow('HTTP 404');
  });
});
