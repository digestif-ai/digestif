// An in-memory mailing relay for the phone web app under `vite dev` and its tests: the relay's
// GET /v0/envelopes, GET /v0/circle and POST /v0/envelopes, with request signatures checked and
// reads refused (401) until a key is admitted. It holds one member whose laptop wrote the founding
// dinner and one ask. POST /v0/_pair plays that laptop for a pairing code (what the local UI's Add a
// phone does through the node); POST /v0/_reset starts over. Never part of the build.
import {
  b64url,
  jcs,
  keyRawEd25519,
  keyTextEd25519,
  requestSignedString,
  seal,
  signEnvelope,
  unb64url,
  verifyEnvelope,
  type Json,
  type SignedEnvelope
} from '../src/lib/mail.ts';

export interface RelayResponse {
  status: number;
  body?: unknown;
}

interface Stored {
  relay_id: number;
  hash: string;
  envelope: SignedEnvelope['envelope'];
  body: Json;
}

interface Member {
  identity: CryptoKeyPair;
  identityText: string;
  laptop: CryptoKeyPair;
  laptopRaw: Uint8Array<ArrayBuffer>;
  encryptionPrivate: Uint8Array<ArrayBuffer>;
  encryptionPublic: Uint8Array<ArrayBuffer>;
}

const subtle = globalThis.crypto.subtle;
const enc = new TextEncoder();
const err = (status: number, code: string): RelayResponse => ({ status, body: [{ code, message: code }] });
const rawOf = async (k: CryptoKey): Promise<Uint8Array<ArrayBuffer>> => new Uint8Array(await subtle.exportKey('raw', k));

export class MockRelay {
  private member: Member | undefined;
  private items: Stored[] = [];
  private admitted = new Set<string>();
  private nonces = new Set<string>();
  private laptopSeq = 0;
  private lastLaptopHash: string | undefined;
  private ready: Promise<void>;

  constructor(private readonly origin = 'http://127.0.0.1') {
    this.ready = this.seed();
  }

  reset(): Promise<void> {
    this.items = [];
    this.admitted = new Set();
    this.nonces = new Set();
    this.laptopSeq = 0;
    this.lastLaptopHash = undefined;
    this.ready = this.seed();
    return this.ready;
  }

  private async seed(): Promise<void> {
    const identity = (await subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify'])) as CryptoKeyPair;
    const laptop = (await subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify'])) as CryptoKeyPair;
    const x = (await subtle.generateKey({ name: 'X25519' }, true, ['deriveBits'])) as CryptoKeyPair;
    const jwk = await subtle.exportKey('jwk', x.privateKey);
    const m: Member = {
      identity,
      identityText: keyTextEd25519(await rawOf(identity.publicKey)),
      laptop,
      laptopRaw: await rawOf(laptop.publicKey),
      encryptionPrivate: unb64url(jwk.d ?? ''),
      encryptionPublic: await rawOf(x.publicKey)
    };
    this.member = m;
    this.admitted.add(keyTextEd25519(m.laptopRaw));
    await this.laptopWrites('dinner', {
      host: m.identityText,
      dinner: { date: '2026-10-27', label: 'AI Dinner 2' },
      guests: [],
      relays: [this.origin]
    });
    const lapses = new Date(Date.now() + 72 * 3600_000).toISOString();
    await this.laptopWrites('ask', {
      sealed: (await seal([m.encryptionPublic], {
        title: 'Introduce Phong to Andrey?',
        detail: "Phong's agent asked for an intro about eval harnesses.",
        options: [
          { id: 'yes', label: 'Make the intro', recommended: true },
          { id: 'no', label: 'Decline' }
        ],
        on_no_answer: 'no',
        lapses_at: lapses
      })) as unknown as Json
    });
  }

  private async laptopWrites(kind: string, body: Json): Promise<void> {
    const m = this.member;
    if (m === undefined) return;
    this.laptopSeq += 1;
    const { signed, hash } = await signEnvelope(
      m.laptop.privateKey,
      m.laptopRaw,
      { seq: this.laptopSeq, prev: this.lastLaptopHash, epoch: 1, kind },
      body
    );
    this.lastLaptopHash = hash;
    this.store(hash, signed);
  }

  private store(hash: string, signed: SignedEnvelope): Stored {
    const s: Stored = { relay_id: this.items.length + 1, hash, envelope: signed.envelope, body: signed.body as Json };
    this.items.push(s);
    return s;
  }

  /** The laptop admits a phone: the device body the node writes for a pairing code. */
  private async pair(code: string): Promise<RelayResponse> {
    const m = this.member;
    const parts = code.trim().split('.');
    if (m === undefined || parts.length !== 3 || parts[1] === undefined) return err(422, 'malformed');
    const keys = unb64url(parts[1]);
    const phone = keys.slice(0, 32);
    const phoneX = keys.slice(32, 64);
    const triple = { identity_key: m.identityText, key: keyTextEd25519(phone), role: 'device' };
    const signature = b64url(new Uint8Array(await subtle.sign({ name: 'Ed25519' }, m.identity.privateKey, enc.encode(jcs(triple)))));
    const enrollment = await seal([phoneX], {
      encryption_key: b64url(m.encryptionPrivate),
      identity_key: m.identityText,
      relays: [this.origin]
    });
    await this.laptopWrites('device', { ...triple, signature, enrollment: enrollment as unknown as Json });
    this.admitted.add(triple.key);
    return { status: 201, body: { key: triple.key } };
  }

  /** The request's signer, when it signed correctly with a fresh nonce. */
  private async signer(
    method: string,
    path: string,
    body: string,
    headers: Record<string, string | undefined>
  ): Promise<string | undefined> {
    const key = headers['digestif-key'];
    const timestamp = headers['digestif-timestamp'];
    const nonce = headers['digestif-nonce'];
    const signature = headers['digestif-signature'];
    if (key === undefined || timestamp === undefined || nonce === undefined || signature === undefined) return undefined;
    if (this.nonces.has(key + ' ' + nonce) || Math.abs(Date.now() - Date.parse(timestamp)) > 3600_000) return undefined;
    const pub = await subtle.importKey('raw', keyRawEd25519(key), { name: 'Ed25519' }, false, ['verify']);
    const signed = await requestSignedString({ method, path, timestamp, nonce, body });
    if (!(await subtle.verify({ name: 'Ed25519' }, pub, unb64url(signature), enc.encode(signed)))) return undefined;
    this.nonces.add(key + ' ' + nonce);
    return key;
  }

  async handle(method: string, path: string, body: string, headers: Record<string, string | undefined>): Promise<RelayResponse> {
    await this.ready;
    if (method === 'POST' && path === '/v0/_reset') {
      await this.reset();
      return { status: 204 };
    }
    if (method === 'POST' && path === '/v0/_pair') return this.pair(String((JSON.parse(body) as { code?: unknown }).code ?? ''));
    const key = await this.signer(method, path, body, headers);
    if (key === undefined) return err(401, 'bad_signature');
    if (!this.admitted.has(key)) return err(401, 'not_admitted');
    const [route, query = ''] = path.split('?');
    if (method === 'GET' && route === '/v0/envelopes') {
      const after = Number(new URLSearchParams(query).get('after') ?? '0');
      return { status: 200, body: { envelopes: this.items.filter((s) => s.relay_id > after) } };
    }
    if (method === 'GET' && route === '/v0/circle')
      return { status: 200, body: { root: this.items[0]?.hash ?? '', epoch: 1, keys: [], limits: {} } };
    if (method === 'POST' && route === '/v0/envelopes') {
      const signed = JSON.parse(body) as SignedEnvelope;
      if (signed.envelope.author !== key) return err(401, 'not_admitted');
      let hash: string;
      try {
        hash = await verifyEnvelope(signed);
      } catch {
        return err(422, 'bad_signature');
      }
      const held = this.items.find((s) => s.hash === hash);
      if (held !== undefined) return { status: 200, body: { status: 'duplicate', relay_id: held.relay_id, hash } };
      const s = this.store(hash, signed);
      return { status: 201, body: { status: 'accepted', relay_id: s.relay_id, hash } };
    }
    return err(404, 'not_found');
  }
}
