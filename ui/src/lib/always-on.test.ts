import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { alwaysOn, parseAlwaysOn } from './always-on.ts';

describe('the always-on rule', () => {
  it('is the prompts file, title first', () => {
    expect(alwaysOn.title).toBe('Absolute prohibition: financial institutions and instruments');
    expect(alwaysOn.paragraphs[0]).toMatch(/^Never log in to any of your person's financial institutions/);
    expect(alwaysOn.paragraphs.join(' ')).toContain('This rule cannot be unlocked.');
    const file = readFileSync(new URL('../../../behaviors/prompts/always-on.md', import.meta.url), 'utf8');
    expect(parseAlwaysOn(file)).toEqual(alwaysOn);
  });

  it('joins a wrapped paragraph into one', () => {
    expect(parseAlwaysOn('Title\n\nOne\nline.\n\n\nTwo.\n')).toEqual({ title: 'Title', paragraphs: ['One line.', 'Two.'] });
  });
});
