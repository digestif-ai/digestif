import { createHash } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { pairingCode } from '#lib/mail.ts';
import { CHECK_MISMATCH, NOT_A_CODE, checkPairingCode } from './pairing.ts';

const keys = Buffer.alloc(64, 9);
const code = 'p1.' + keys.toString('base64url') + '.' + createHash('sha256').update(keys).digest().subarray(0, 3).toString('base64url');

describe('checkPairingCode', () => {
  it('accepts the code the phone web app builds', async () => {
    const built = await pairingCode(new Uint8Array(32).fill(1), new Uint8Array(32).fill(2));
    expect(await checkPairingCode(built)).toEqual({ state: 'ok' });
    expect(await checkPairingCode(code)).toEqual({ state: 'ok' });
  });

  it('ignores the spaces a paste picked up', async () => {
    expect(await checkPairingCode('  ' + code.slice(0, 20) + ' ' + code.slice(20) + '\n')).toEqual({ state: 'ok' });
  });

  it('says nothing before anything is typed', async () => {
    expect(await checkPairingCode('   ')).toEqual({ state: 'empty' });
  });

  it('says a wrong check does not match', async () => {
    const wrong = code.slice(0, -1) + (code.endsWith('A') ? 'B' : 'A');
    expect(await checkPairingCode(wrong)).toEqual({ state: 'mistyped', message: CHECK_MISMATCH });
  });

  it('says what is not a pairing code at all', async () => {
    for (const bad of ['hello', 'p1.AAAA.AAAA', 'p2' + code.slice(2), code.slice(0, 40), code + '.x', 'p1.' + '+'.repeat(86) + '.AAAA'])
      expect(await checkPairingCode(bad)).toEqual({ state: 'mistyped', message: NOT_A_CODE });
  });
});
