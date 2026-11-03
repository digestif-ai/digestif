import { describe, expect, it } from 'vitest';
import { phonesOf } from './phones.ts';

describe('phonesOf', () => {
  const d = (key: string, role: string, at: string, phone = false) => ({ key, role, admitted_at: at, phone });

  it('keeps the devices the node flags as phones, the oldest first', () => {
    const phones = phonesOf([
      d('phone-2', 'device', '2026-03-01T00:00:00Z', true),
      d('node', 'device', '2026-01-01T00:00:00Z'),
      d('mail', 'mail', '2025-12-01T00:00:00Z'),
      d('phone-1', 'device', '2026-02-01T00:00:00Z', true)
    ]);
    expect(phones.map((p) => p.key)).toEqual(['phone-1', 'phone-2']);
  });

  it('reads a device with no phone flag as no phone', () => {
    const unflagged = { key: 'old', role: 'device', admitted_at: '2026-01-01T00:00:00Z' };
    expect(phonesOf([unflagged, d('phone-1', 'device', '2026-02-01T00:00:00Z', true)]).map((p) => p.key)).toEqual(['phone-1']);
  });

  it('leaves out a second machine, which is no phone', () => {
    expect(phonesOf([d('node', 'device', '2026-01-01T00:00:00Z'), d('laptop', 'device', '2026-02-01T00:00:00Z')])).toEqual([]);
  });
});
