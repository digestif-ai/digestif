// An in-memory mailing relay for the phone web app under `vite dev` and its tests: the relay's
// GET /v0/envelopes, GET /v0/circle and POST /v0/envelopes, with request signatures checked and
// reads refused (401) until a key is admitted. It holds one member whose laptop wrote the founding
// dinner, their card, their node's join choice and a Note ready notice, and a second member, Ada,
// whose behavior choice and question are addressed to the first, and whose other question is
// addressed to the circle (docs/protocol.md, Items). POST /v0/_pair plays
// that laptop for a pairing code (what the local UI's Add a phone does through the node); POST
// /v0/_paused plays it pressing Pause, which sends the Paused status note, and with `{ "by": "node" }`
// plays the node pausing after a note waited 30 days, which also raises the Paused choice; POST
// /v0/_reset starts over. Never part of the build.
import {
  b64url,
  jcs,
  keyRawEd25519,
  keyTextEd25519,
  keyTextX25519,
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

interface Other {
  device: CryptoKeyPair;
  deviceRaw: Uint8Array<ArrayBuffer>;
  identityText: string;
  encryptionPublic: Uint8Array<ArrayBuffer>;
  seq: number;
  last?: string;
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
  private ada: Other | undefined;

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
    await this.laptopWrites('card', { name: 'Sam Lee', agent_name: 'Hermes', encryption_key: keyTextX25519(m.encryptionPublic) });
    await this.laptopWrites('item', {
      to: [m.identityText],
      sealed: (await seal([m.encryptionPublic], {
        kind: 'choice',
        subject: 'join',
        voice: 'node',
        title: 'Roman Cherkasov joined. Keep them in?',
        detail: 'You have not said you heard from Roman since the dinner.',
        options: [
          { id: 'keep', label: 'Keep them in', recommended: true },
          { id: 'remove', label: 'Remove them' }
        ],
        default: 'keep',
        deadline: new Date(Date.now() + 72 * 3600_000).toISOString()
      })) as unknown as Json
    });
    await this.laptopWrites('item', {
      to: [m.identityText],
      sealed: (await seal([m.encryptionPublic], {
        kind: 'notice',
        subject: 'note_ready',
        voice: 'node',
        title: 'Your note is ready',
        detail: 'Your Nov 6 note waits for your approval.'
      })) as unknown as Json
    });
    await this.adaJoins(m);
  }

  /** A second member: her join, her card, a behavior choice and a question she addresses to the first, and a circle question. */
  private async adaJoins(m: Member): Promise<void> {
    const invite = (await subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify'])) as CryptoKeyPair;
    const identity = (await subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify'])) as CryptoKeyPair;
    const device = (await subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify'])) as CryptoKeyPair;
    const x = (await subtle.generateKey({ name: 'X25519' }, true, ['deriveBits'])) as CryptoKeyPair;
    const ada: Other = {
      device,
      deviceRaw: await rawOf(device.publicKey),
      identityText: keyTextEd25519(await rawOf(identity.publicKey)),
      encryptionPublic: await rawOf(x.publicKey),
      seq: 0
    };
    this.ada = ada;
    const inviteRaw = await rawOf(invite.publicKey);
    const join = await signEnvelope(
      invite.privateKey,
      inviteRaw,
      { seq: 1, epoch: 0, kind: 'join' },
      { dinner: this.items[0]?.hash ?? '', identity_key: ada.identityText, device_key: keyTextEd25519(ada.deviceRaw) }
    );
    this.store(join.hash, join.signed);
    await this.adaWrites('card', { name: 'Ada Park', agent_name: 'Juno', encryption_key: keyTextX25519(ada.encryptionPublic) });
    await this.adaWrites('item', {
      to: [m.identityText],
      sealed: (await seal([m.encryptionPublic, ada.encryptionPublic], {
        kind: 'choice',
        subject: 'behavior',
        voice: 'agent',
        title: "Install Ada's eval-harness behavior?",
        detail: 'It runs the eval suite before each note and names regressions in Stuck on.',
        options: [
          { id: 'install', label: 'Install' },
          { id: 'not_now', label: 'Not now', recommended: true }
        ],
        default: 'not_now'
      })) as unknown as Json
    });
    await this.adaWrites('item', {
      to: [m.identityText],
      sealed: (await seal([m.encryptionPublic, ada.encryptionPublic], {
        kind: 'question',
        voice: 'person',
        title: 'Could you introduce me to Roman?',
        detail: 'I would like to ask him about his eval harness.'
      })) as unknown as Json
    });
    await this.adaWrites('item', {
      to: 'circle',
      item: { kind: 'question', subject: 'note_question', voice: 'agent', title: 'Who has a good eval set for coding agents?', detail: '' }
    });
  }

  private async adaWrites(kind: string, body: Json): Promise<void> {
    const a = this.ada;
    if (a === undefined) return;
    a.seq += 1;
    const { signed, hash } = await signEnvelope(a.device.privateKey, a.deviceRaw, { seq: a.seq, prev: a.last, epoch: 2, kind }, body);
    a.last = hash;
    this.store(hash, signed);
  }

  /** The Paused choice the node raises when it pauses the member: no deadline, Stay paused standing. */
  private async pausedChoice(): Promise<void> {
    const m = this.member;
    if (m === undefined) return;
    await this.laptopWrites('item', {
      to: [m.identityText],
      sealed: (await seal([m.encryptionPublic], {
        kind: 'choice',
        subject: 'paused',
        voice: 'node',
        title: 'Digestif paused. Unpause?',
        detail: 'Your note waited 30 days, so Digestif paused. No notes are written while it stays paused.',
        options: [
          { id: 'unpause', label: 'Unpause', recommended: true },
          { id: 'stay_paused', label: 'Stay paused' }
        ],
        default: 'stay_paused'
      })) as unknown as Json
    });
  }

  /** How many envelopes of [kind] the relay holds sealed to Ada: a pick on her choice, or an answer to her question, reaches its author. */
  private sealedToAda(kind: string): number {
    const ada = this.ada === undefined ? undefined : keyTextX25519(this.ada.encryptionPublic);
    return this.items.filter((s) => {
      const sealed = (s.body as { sealed?: { recipients?: { key: string }[] } } | null)?.sealed;
      return s.envelope.kind === kind && sealed?.recipients?.some((r) => r.key === ada) === true;
    }).length;
  }

  /** How many answers the relay holds in the clear: an answer to a circle question. */
  private plainAnswers(): number {
    return this.items.filter((s) => s.envelope.kind === 'item_answer' && typeof (s.body as { text?: unknown } | null)?.text === 'string')
      .length;
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
    if (method === 'POST' && path === '/v0/_paused') {
      await this.laptopWrites('summary', { status: 'paused', voice: 'agent', stage: 'paused' });
      if (body !== '' && (JSON.parse(body) as { by?: unknown }).by === 'node') await this.pausedChoice();
      return { status: 204 };
    }
    if (method === 'GET' && path === '/v0/_sealed_to_ada')
      return {
        status: 200,
        body: { decisions: this.sealedToAda('decision'), answers: this.sealedToAda('item_answer'), plain_answers: this.plainAnswers() }
      };
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
