import { render } from 'svelte/server';
import { describe, expect, it } from 'vitest';
import BrandVersion from './BrandVersion.svelte';

const html = (version?: string): string => render(BrandVersion, { props: { version } }).body;

describe('the header version (DIG-523)', () => {
  it('shows the version the status carries', () => {
    const out = html('1.2.3');
    expect(out).toContain('data-testid="node-version"');
    expect(out).toContain('1.2.3');
  });

  it('shows nothing when the status has none', () => {
    expect(html(undefined)).not.toContain('node-version');
    expect(html('')).not.toContain('node-version');
  });
});
