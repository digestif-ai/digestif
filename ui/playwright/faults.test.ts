import { describe, expect, it } from 'vitest';
import { infraReason, infraVerdict, isNetworkChanged, NETWORK_CHANGED, retryReason, type FinalTest } from './faults.ts';

const quiet = { closedUnder: false, networkChanged: false };

describe('retryReason', () => {
  it('refuses an attempt the machine did not fail', () => {
    expect(retryReason(quiet)).toBeUndefined();
  });

  it('admits a page that closed under the test', () => {
    expect(retryReason({ ...quiet, closedUnder: true })).toContain('closed under it');
  });

  it('admits requests aborted on a network change', () => {
    expect(retryReason({ ...quiet, networkChanged: true })).toContain(NETWORK_CHANGED);
  });
});

describe('infraReason', () => {
  it('calls only a network change an infra fault', () => {
    expect(infraReason({ ...quiet, closedUnder: true })).toBeUndefined();
    expect(infraReason({ ...quiet, networkChanged: true })).toContain(NETWORK_CHANGED);
  });
});

describe('isNetworkChanged', () => {
  it('matches Chromium error text', () => {
    expect(isNetworkChanged('net::ERR_NETWORK_CHANGED')).toBe(true);
    expect(isNetworkChanged('net::ERR_ABORTED')).toBe(false);
    expect(isNetworkChanged(undefined)).toBe(false);
  });
});

describe('infraVerdict', () => {
  const test = (outcome: FinalTest['outcome'], infra?: string): FinalTest => ({ title: 't', outcome, infra });

  it('is undefined when nothing failed', () => {
    expect(infraVerdict([test('expected'), test('flaky', 'x')])).toBeUndefined();
  });

  it('is undefined when any failure was the code', () => {
    expect(infraVerdict([test('unexpected', 'network'), test('unexpected')])).toBeUndefined();
  });

  it('names every failure when all were the machine', () => {
    expect(infraVerdict([test('expected'), test('unexpected', 'network')])).toEqual(['t: network']);
  });
});
