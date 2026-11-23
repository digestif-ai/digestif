// The phone reaches its circle at the home circle's address on the relay serving it, read once from
// GET /v0/relay, since a relay drops the unprefixed circle routes (docs/protocol.md, Hosted
// circles).
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { generatePhoneKeys } from '#lib/mail.ts';
import type { PhoneKeys } from './keystore.ts';
import { circle, circleAddress, forgetCircleAddress } from './relay.ts';

const HEX = '004169dcdcd761ec470e2279c832a3f5684fc25e97bd5d3766397de373f53ba3';

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
}

async function phoneKeys(): Promise<PhoneKeys> {
  const k = await generatePhoneKeys();
  return { signing: k.signing.privateKey, sealing: k.sealing.privateKey, ed25519: k.ed25519, x25519: k.x25519, code: k.code };
}

beforeEach(() => {
  forgetCircleAddress();
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('the circle address', () => {
  it('is the home circle read from GET /v0/relay, read once', async () => {
    const get = vi.fn(() => Promise.resolve(json(200, { home: `sha256:${HEX}`, hosting: true, mailer: true })));
    expect(await circleAddress(get)).toEqual({ ok: true, data: `/c/${HEX}` });
    expect(await circleAddress(get)).toEqual({ ok: true, data: `/c/${HEX}` });
    expect(get).toHaveBeenCalledTimes(1);
    expect(get).toHaveBeenCalledWith('/v0/relay');
  });

  it('is a failure, asked again next time, on a relay with no home circle or no answer', async () => {
    expect(await circleAddress(() => Promise.resolve(json(200, { home: null })))).toMatchObject({ ok: false, status: 404 });
    expect(await circleAddress(() => Promise.reject(new Error('offline')))).toMatchObject({ ok: false, status: 0 });
    expect(await circleAddress(() => Promise.resolve(json(500, {})))).toMatchObject({ ok: false, status: 500 });
    expect(await circleAddress(() => Promise.resolve(json(200, { home: `sha256:${HEX}` })))).toEqual({ ok: true, data: `/c/${HEX}` });
  });

  it('prefixes every circle route the phone signs and sends', async () => {
    const asked: string[] = [];
    vi.stubGlobal('fetch', (input: string, init?: RequestInit) => {
      asked.push(`${init?.method ?? 'GET'} ${input}`);
      if (input === '/v0/relay') return Promise.resolve(json(200, { home: `sha256:${HEX}` }));
      return Promise.resolve(json(200, { epoch: 3 }));
    });
    expect(await circle(await phoneKeys())).toEqual({ ok: true, data: { epoch: 3 } });
    expect(asked).toEqual(['GET /v0/relay', `GET /c/${HEX}/v0/circle`]);
  });
});
