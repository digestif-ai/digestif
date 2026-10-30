// The suite's side of a circle: the host, the members each case invites, and the relays they write
// to. Every case builds its own members through a dinner of its own, so cases never share keys and
// a relay that already holds earlier runs is as good a target as a fresh one.
import "./node-crypto.ts"; // installs the node:crypto SuiteCrypto: this module only runs on Node
import { randomBytes } from "node:crypto";
import { deviceBody, dinnerBody, joinBody, INVITE_TTL_MS, revokeBody, summaryBody, type Guest } from "./bodies.ts";
import { isoTime, jcs, type Json } from "./encoding.ts";
import { Author, envelopeHash, signEnvelope, type Kind, type SignedEnvelope, type StoredEnvelope } from "./envelope.ts";
import { Signer } from "./keys.ts";
import { RelayClient, type HttpResult, type SignOptions } from "./request.ts";
import { TestCircle } from "./circle.ts";

export class Member {
  readonly name: string;
  readonly identity: Signer;
  readonly devices: Author[];
  joinHash = "";

  constructor(name: string, identity: Signer, device: Author) {
    this.name = name;
    this.identity = identity;
    this.devices = [device];
  }

  get device(): Author {
    const device = this.devices[0];
    if (device === undefined) throw new Error(`${this.name} has no device`);
    return device;
  }
}

export interface Invitation {
  name: string;
  invite: Signer;
  dinnerHash: string;
}

export class World {
  readonly circle: TestCircle;
  readonly urls: string[];
  readonly host: Member;
  /** A run-unique tag, so text written by one run is told apart from another's. */
  readonly tag = randomBytes(4).toString("hex");

  constructor(circle: TestCircle, urls: string[]) {
    this.circle = circle;
    this.urls = urls;
    this.host = new Member("host", circle.hostIdentity, new Author(circle.hostDevice));
  }

  client(url: string, author: Author | Signer): RelayClient {
    return new RelayClient(url, author instanceof Author ? author.signer : author);
  }

  relay(index: number): string {
    const url = this.urls[index];
    if (url === undefined) throw new Error(`relay ${index} is not configured`);
    return url;
  }

  /** Appends the root dinner everywhere and continues the host's chain from the highest seq any relay holds. */
  async setup(): Promise<void> {
    let last: StoredEnvelope | undefined;
    for (const url of this.urls) {
      const result = await this.client(url, this.host.device).append(this.circle.root, { unsigned: true });
      if (result.status !== 201 && result.status !== 200) {
        throw new Error(`${url} refused the test circle's root dinner (${result.status}): ${result.text}`);
      }
      for (const stored of await this.client(url, this.host.device).fetchAll()) {
        if (stored.envelope.author === this.host.device.key && (last === undefined || stored.envelope.seq > last.envelope.seq)) {
          last = stored;
        }
      }
    }
    if (last !== undefined) {
      this.host.device.seq = last.envelope.seq;
      this.host.device.prev = envelopeHash(last.envelope);
    }
  }

  async epoch(url: string = this.relay(0)): Promise<number> {
    const result = await this.client(url, this.host.device).circle();
    if (result.status !== 200) throw new Error(`GET /v0/circle on ${url} answered ${result.status}: ${result.text}`);
    return (result.body as { epoch: number }).epoch;
  }

  async appendTo(urls: string[], author: Author | Signer, signed: SignedEnvelope, options: SignOptions = {}): Promise<HttpResult[]> {
    const results: HttpResult[] = [];
    for (const url of urls) results.push(await this.client(url, author).append(signed, options));
    return results;
  }

  /** Appends everywhere and fails unless every relay accepted or already held it. */
  async publish(urls: string[], author: Author | Signer, signed: SignedEnvelope, options: SignOptions = {}): Promise<string> {
    for (const result of await this.appendTo(urls, author, signed, options)) {
      if (result.status !== 201 && result.status !== 200) {
        throw new Error(`setup append of a ${signed.envelope.kind} to ${result.request.url} answered ${result.status}: ${result.text}`);
      }
    }
    return envelopeHash(signed.envelope);
  }

  /** The host writes a dinner naming fresh invite keys. `expired` writes invites already past their expiry. */
  async dinner(names: string[], urls: string[] = this.urls, options: { expired?: boolean } = {}): Promise<Invitation[]> {
    const invites = names.map((name) => ({ name, invite: Signer.random() }));
    const expiresAt = new Date(Date.now() + (options.expired ? -3600 * 1000 : INVITE_TTL_MS));
    const guests: Guest[] = invites.map((i) => ({ name: i.name, invite_key: i.invite.key, expires_at: isoTime(expiresAt) }));
    const body = dinnerBody(this.host.identity, `conformance ${this.tag} ${names.join(", ")}`, guests, this.urls);
    const signed = this.host.device.next("dinner", body, await this.epoch(urls[0]));
    const dinnerHash = await this.publish(urls, this.host.device, signed);
    return invites.map((i) => ({ ...i, dinnerHash }));
  }

  /** The join a guest's app posts, unsigned as a bootstrap append: the invite key's only envelope,
   * seq 1, no prev, epoch 0. Not yet sent. */
  joinFor(invitation: Invitation, createdAt?: Date): { member: Member; signed: SignedEnvelope } {
    const identity = Signer.random();
    const device = new Author(Signer.random());
    const signed = signEnvelope(invitation.invite, {
      kind: "join",
      body: joinBody(invitation.dinnerHash, invitation.invite, identity, device.signer),
      seq: 1,
      epoch: 0,
      ...(createdAt === undefined ? {} : { createdAt }),
    });
    const member = new Member(invitation.name, identity, device);
    member.joinHash = envelopeHash(signed.envelope);
    return { member, signed };
  }

  /** Invites and joins members in one step, on the given relays. */
  async members(names: string[], urls: string[] = this.urls): Promise<Member[]> {
    const members: Member[] = [];
    for (const invitation of await this.dinner(names, urls)) {
      const { member, signed } = this.joinFor(invitation);
      await this.publish(urls, member.device, signed, { unsigned: true });
      members.push(member);
    }
    return members;
  }

  /** Adds a device or mail key to a member, signed by their identity, posted by their first device. */
  async addDevice(member: Member, role: "device" | "mail", urls: string[] = this.urls): Promise<Author> {
    const key = new Author(Signer.random());
    const signed = member.device.next("device", deviceBody(member.identity, key.key, role), await this.epoch(urls[0]));
    await this.publish(urls, member.device, signed);
    member.devices.push(key);
    return key;
  }

  /**
   * The device message a member's replacement laptop posts when no device of theirs is left: authored
   * by the new key itself, seq 1, naming the member's identity, its authority the identity signature
   * inside it. `signer` makes that signature: the member's identity unless a case forges it. Not yet
   * sent; a bootstrap append, so unsigned.
   */
  async selfDevice(member: Member, signer: Signer = member.identity, url: string = this.relay(0)): Promise<{ device: Author; signed: SignedEnvelope }> {
    const device = new Author(Signer.random());
    const named = { identity_key: member.identity.key, key: device.key, role: "device" };
    const body = { ...named, signature: signer.sign(jcs(named)) };
    const signed = device.next("device", body, await this.epoch(url));
    return { device, signed };
  }

  /**
   * Signs a revoke of `target` by `by`, posted as `author`. Not yet sent. `stops` are the device
   * authors the revoke stops; each one's cutoff is its chain's seq as this world last signed it.
   * `mailRead` maps each mail key it stops to the hashes of that key's envelopes the revoker holds.
   */
  async revoke(
    author: Author,
    by: Signer,
    target: string,
    stops: Author[],
    url: string = this.relay(0),
    createdAt?: Date,
    mailRead: Record<string, string[]> = {},
  ): Promise<SignedEnvelope> {
    const afterSeq = Object.fromEntries(stops.map((s) => [s.key, s.seq]));
    return author.next("revoke", revokeBody(by, target, afterSeq, mailRead), await this.epoch(url), createdAt);
  }

  /** Signs the author's next summary. Not yet sent. */
  async summary(author: Author, text: string, url: string = this.relay(0), createdAt?: Date): Promise<SignedEnvelope> {
    return author.next("summary", summaryBody(`${text} (${this.tag})`), await this.epoch(url), createdAt);
  }

  /** Signs and publishes the author's next message of any kind. */
  async post(author: Author, text: string, urls: string[] = this.urls, kind: Kind = "summary", body?: Json): Promise<SignedEnvelope> {
    const signed = author.next(kind, body ?? summaryBody(`${text} (${this.tag})`), await this.epoch(urls[0]));
    await this.publish(urls, author, signed);
    return signed;
  }
}
