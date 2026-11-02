import { describe, expect, it } from 'vitest';
import { phonesOf } from './phones.ts';

describe('phonesOf', () => {
  it('leaves out this machine, the first device admitted, and the mail key', () => {
    const d = (key: string, role: string, at: string) => ({ key, role, admitted_at: at });
    const phones = phonesOf([
      d('phone-2', 'device', '2026-03-01T00:00:00Z'),
      d('node', 'device', '2026-01-01T00:00:00Z'),
      d('mail', 'mail', '2025-12-01T00:00:00Z'),
      d('phone-1', 'device', '2026-02-01T00:00:00Z')
    ]);
    expect(phones.map((p) => p.key)).toEqual(['phone-1', 'phone-2']);
  });

  it('has no phones before one is added', () => {
    expect(phonesOf([{ key: 'node', role: 'device', admitted_at: '2026-01-01T00:00:00Z' }])).toEqual([]);
  });
});
