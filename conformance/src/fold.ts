// The admission fold, docs/protocol.md "The admission fold". One implementation shared by the fake
// relay (folding in relay order) and the reference node (folding the union of relays in its
// canonical order), so the two can never disagree about who is admitted.
import { jcs, type Json } from "./encoding.ts";
import { verifySignature } from "./keys.ts";
import { isCircleState, type Envelope } from "./envelope.ts";

export type FoldError = "malformed" | "bad_signature" | "not_admitted" | "wrong_circle" | "retract_not_author";
export type Role = "identity" | "device" | "mail";

export interface KeyState {
  key: string;
  role: Role;
  identity: string;
  admitted_at: number;
  join_epoch: number;
  revoked_at?: number;
  /** For a revoked device key, the highest seq still read from it: the revoke's `after_seq` entry, or 0. */
  after_seq?: number;
  /** For a revoked mail key, the envelope hashes still read from it: the revoke's `mail_read` entry, or none. */
  mail_read?: ReadonlySet<string>;
}

interface Invite {
  dinner: string;
  expires_at: string;
  spent: boolean;
}

export interface FoldInput {
  hash: string;
  envelope: Envelope;
  body: Json | undefined;
  /** Where the envelope sits in the fold: the relay_id on a relay, the merge index on a node. */
  position: number;
  /** The time an invite's expiry is judged against. */
  now: Date;
}

function isObject(value: Json | undefined): value is { [key: string]: Json } {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function str(body: { [key: string]: Json }, field: string): string | undefined {
  const value = body[field];
  return typeof value === "string" ? value : undefined;
}

/**
 * A revoke's `after_seq`: device key to the last seq of that key's honest chain, a non-negative
 * integer. Undefined when the field is absent or not of that shape.
 */
function parseAfterSeq(value: Json | undefined): Map<string, number> | undefined {
  if (!isObject(value)) return undefined;
  const cutoffs = new Map<string, number>();
  for (const [key, seq] of Object.entries(value)) {
    if (typeof seq !== "number" || !Number.isInteger(seq) || seq < 0) return undefined;
    cutoffs.set(key, seq);
  }
  return cutoffs;
}

const HASH = /^sha256:[0-9a-f]{64}$/;

/**
 * A revoke's `mail_read`: mail key to the hashes of its envelopes the revoker holds, each an envelope
 * hash. Undefined when the field is absent or not of that shape.
 */
function parseMailRead(value: Json | undefined): Map<string, Set<string>> | undefined {
  if (!isObject(value)) return undefined;
  const reads = new Map<string, Set<string>>();
  for (const [key, hashes] of Object.entries(value)) {
    if (!Array.isArray(hashes) || !hashes.every((h) => typeof h === "string" && HASH.test(h))) return undefined;
    reads.set(key, new Set(hashes as string[]));
  }
  return reads;
}

/** Rules a fold can be told to skip, so the self-test can prove each case catches its absence. */
export type FoldBreak = "expiry" | "spent" | "revocation" | "retract-author" | "cutoff-shape" | "mail-cutoff" | "self-device" | "device-signature";

export interface FoldOptions {
  breaks?: Iterable<FoldBreak>;
  /**
   * A node reads a revoked key by its cutoff, wherever the envelope sits in the fold: a device key at
   * or below `after_seq` and none above, a mail key the envelopes `mail_read` lists and no other. A
   * relay leaves this off and refuses every append from a revoked key from the revoke on.
   */
  readsCutoffs?: boolean;
}

export class Fold {
  readonly root: string;
  readonly breaks: ReadonlySet<FoldBreak>;
  readonly readsCutoffs: boolean;
  rootFolded = false;
  epoch = 0;
  readonly keys = new Map<string, KeyState>();
  private readonly invites = new Map<string, Invite>();
  /** Dinner hash to the identity of the host who wrote it. */
  private readonly dinners = new Map<string, string>();
  /** Identity to the host identity whose dinner admitted it. */
  private readonly admittedBy = new Map<string, string>();
  /** Envelope hash to its author key, for the retract rule. */
  private readonly authorOf = new Map<string, string>();

  constructor(root: string, options: FoldOptions = {}) {
    this.root = root;
    this.breaks = new Set(options.breaks ?? []);
    this.readsCutoffs = options.readsCutoffs ?? false;
  }

  /**
   * An admitted device or mail key that may author the envelope at `seq` with hash `hash`: unrevoked,
   * or, on a fold that reads cutoffs, a revoked key inside its cutoff. Without an envelope (a request
   * rather than an append) a revoked key is never active.
   */
  activeAuthor(key: string, envelope?: { seq: number; hash: string }): KeyState | undefined {
    const state = this.keys.get(key);
    if (state === undefined || state.role === "identity") return undefined;
    if (state.revoked_at === undefined || this.breaks.has("revocation")) return state;
    return this.readsCutoffs && envelope !== undefined && this.withinCutoff(state, envelope) ? state : undefined;
  }

  /**
   * A revoked device key is read at or below `after_seq`; a revoked mail key is read by the hashes
   * `mail_read` lists, since a chainless key's author can write any seq. A fold told to skip the mail
   * cutoff reads a mail key up to the revoke in fold order instead, the rule this one replaced.
   */
  private withinCutoff(state: KeyState, envelope: { seq: number; hash: string }): boolean {
    if (state.after_seq !== undefined) return envelope.seq <= state.after_seq;
    if (state.mail_read !== undefined && !this.breaks.has("mail-cutoff")) return state.mail_read.has(envelope.hash);
    return false;
  }

  /** True when a fold that reads cutoffs must not read this envelope: its author is revoked and it is outside the cutoff. */
  pastCutoff(envelope: Envelope, hash: string): boolean {
    const state = this.keys.get(envelope.author);
    if (state === undefined || this.breaks.has("revocation")) return false;
    if (state.after_seq !== undefined) return envelope.seq > state.after_seq;
    if (state.mail_read !== undefined && !this.breaks.has("mail-cutoff")) return !state.mail_read.has(hash);
    return false;
  }

  /** The hash of the dinner that lists an invite key, while the invite is unspent and unexpired. */
  openInvite(key: string, now: Date): string | undefined {
    const invite = this.invites.get(key);
    if (invite === undefined || invite.spent) return undefined;
    if (Date.parse(invite.expires_at) <= now.getTime() && !this.breaks.has("expiry")) return undefined;
    return invite.dinner;
  }

  identityOf(key: string): string | undefined {
    return this.keys.get(key)?.identity;
  }

  authorOfEnvelope(hash: string): string | undefined {
    return this.authorOf.get(hash);
  }

  /** Folds one envelope. Returns the refusal and changes nothing, or returns null having applied it. */
  apply(input: FoldInput): FoldError | null {
    const error = this.applyKind(input);
    if (error === null) this.authorOf.set(input.hash, input.envelope.author);
    return error;
  }

  private applyKind(input: FoldInput): FoldError | null {
    const { envelope, body } = input;
    if (!this.rootFolded) {
      if (envelope.kind !== "dinner" || input.hash !== this.root) return "wrong_circle";
      return this.foldRoot(input);
    }
    if (!isCircleState(envelope.kind) || envelope.kind === "card" || envelope.kind === "relay") {
      if (this.activeAuthor(envelope.author, { seq: envelope.seq, hash: input.hash }) === undefined) return "not_admitted";
      if (envelope.kind === "retract") return this.checkRetract(envelope, body);
      return null;
    }
    if (!isObject(body)) return "malformed";
    switch (envelope.kind) {
      case "dinner":
        return this.foldDinner(input, body);
      case "join":
        return this.foldJoin(input, body);
      case "device":
        return this.foldDevice(input, body);
      case "revoke":
        return this.foldRevoke(input, body);
      default:
        return "malformed";
    }
  }

  private recordGuests(dinnerHash: string, body: { [key: string]: Json }): FoldError | null {
    const guests = body["guests"];
    if (!Array.isArray(guests)) return "malformed";
    const parsed: Array<[string, string]> = [];
    for (const guest of guests) {
      if (!isObject(guest)) return "malformed";
      const invite = str(guest, "invite_key");
      const expires = str(guest, "expires_at");
      if (invite === undefined || expires === undefined || Number.isNaN(Date.parse(expires))) return "malformed";
      parsed.push([invite, expires]);
    }
    for (const [invite, expires] of parsed) {
      if (!this.invites.has(invite)) this.invites.set(invite, { dinner: dinnerHash, expires_at: expires, spent: false });
    }
    return null;
  }

  private foldRoot(input: FoldInput): FoldError | null {
    const { envelope, body } = input;
    if (!isObject(body)) return "malformed";
    const host = str(body, "host");
    if (host === undefined) return "malformed";
    const guestError = this.recordGuests(input.hash, body);
    if (guestError !== null) return guestError;
    this.rootFolded = true;
    this.dinners.set(input.hash, host);
    this.keys.set(host, { key: host, role: "identity", identity: host, admitted_at: input.position, join_epoch: 0 });
    this.keys.set(envelope.author, {
      key: envelope.author,
      role: "device",
      identity: host,
      admitted_at: input.position,
      join_epoch: 0,
    });
    return null;
  }

  private foldDinner(input: FoldInput, body: { [key: string]: Json }): FoldError | null {
    const author = this.activeAuthor(input.envelope.author, { seq: input.envelope.seq, hash: input.hash });
    if (author === undefined || author.role !== "device") return "not_admitted";
    if (str(body, "host") !== author.identity) return "malformed";
    const guestError = this.recordGuests(input.hash, body);
    if (guestError !== null) return guestError;
    this.dinners.set(input.hash, author.identity);
    return null;
  }

  private foldJoin(input: FoldInput, body: { [key: string]: Json }): FoldError | null {
    const inviteKey = input.envelope.author;
    const dinner = str(body, "dinner");
    const identity = str(body, "identity_key");
    const identitySignature = str(body, "identity_signature");
    const device = str(body, "device_key");
    const deviceSignature = str(body, "device_signature");
    if (!dinner || !identity || !identitySignature || !device || !deviceSignature) return "malformed";
    const invite = this.invites.get(inviteKey);
    if (invite === undefined || (invite.spent && !this.breaks.has("spent")) || invite.dinner !== dinner || !this.dinners.has(dinner)) {
      return "not_admitted";
    }
    if (Date.parse(invite.expires_at) <= input.now.getTime() && !this.breaks.has("expiry")) return "not_admitted";
    if (!verifySignature(inviteKey, jcs({ dinner, identity_key: identity }), identitySignature)) return "bad_signature";
    if (!verifySignature(identity, jcs({ identity_key: identity, device_key: device, role: "device" }), deviceSignature)) {
      return "bad_signature";
    }
    if ((this.keys.has(identity) || this.keys.has(device)) && !this.breaks.has("spent")) return "not_admitted";
    invite.spent = true;
    this.epoch += 1;
    const host = this.dinners.get(dinner);
    if (host !== undefined) this.admittedBy.set(identity, host);
    const base = { identity, admitted_at: input.position, join_epoch: this.epoch };
    this.keys.set(identity, { key: identity, role: "identity", ...base });
    this.keys.set(device, { key: device, role: "device", ...base });
    return null;
  }

  /**
   * A device message's authority is the identity signature inside it, so its author is either an
   * admitted device of that identity or the new key itself: the second is how a member who lost
   * their only laptop gets a new one in, with no other device left to post from.
   */
  private foldDevice(input: FoldInput, body: { [key: string]: Json }): FoldError | null {
    const identity = str(body, "identity_key");
    const key = str(body, "key");
    const role = str(body, "role");
    const signature = str(body, "signature");
    if (!identity || !key || !signature || (role !== "device" && role !== "mail")) return "malformed";
    const selfAuthored = input.envelope.author === key && !this.breaks.has("self-device");
    if (!selfAuthored) {
      const author = this.activeAuthor(input.envelope.author, { seq: input.envelope.seq, hash: input.hash });
      if (author === undefined || author.role !== "device") return "not_admitted";
      if (identity !== author.identity) return "not_admitted";
    }
    const identityState = this.keys.get(identity);
    if (identityState === undefined || identityState.role !== "identity" || identityState.revoked_at !== undefined) return "not_admitted";
    if (!verifySignature(identity, jcs({ identity_key: identity, key, role }), signature) && !this.breaks.has("device-signature")) return "bad_signature";
    if (this.keys.has(key)) return "not_admitted";
    this.keys.set(key, { key, role, identity, admitted_at: input.position, join_epoch: identityState.join_epoch });
    return null;
  }

  private foldRevoke(input: FoldInput, body: { [key: string]: Json }): FoldError | null {
    const author = this.activeAuthor(input.envelope.author, { seq: input.envelope.seq, hash: input.hash });
    if (author === undefined || author.role !== "device") return "not_admitted";
    const target = str(body, "target");
    const by = str(body, "by");
    const signature = str(body, "signature");
    const afterSeq = parseAfterSeq(body["after_seq"]);
    const mailRead = parseMailRead(body["mail_read"]);
    if (!target || !by || !signature) return "malformed";
    if ((afterSeq === undefined || mailRead === undefined) && !this.breaks.has("cutoff-shape")) return "malformed";
    if (author.identity !== by) return "not_admitted";
    const byState = this.keys.get(by);
    if (byState === undefined || byState.role !== "identity" || byState.revoked_at !== undefined) return "not_admitted";
    const signed = {
      target,
      by,
      ...(body["after_seq"] === undefined ? {} : { after_seq: body["after_seq"] }),
      ...(body["mail_read"] === undefined ? {} : { mail_read: body["mail_read"] }),
    };
    if (!verifySignature(by, jcs(signed), signature)) return "bad_signature";
    const targetState = this.keys.get(target);
    if (targetState === undefined) return "not_admitted";
    if (targetState.role === "identity") {
      if (by !== target && by !== this.admittedBy.get(target)) return "not_admitted";
    } else if (targetState.identity !== by) {
      return "not_admitted";
    }
    const stopped = [...this.keys.values()].filter((s) => (targetState.role === "identity" ? s.identity === target : s.key === target));
    const cutoffs = afterSeq ?? new Map<string, number>();
    const reads = mailRead ?? new Map<string, Set<string>>();
    const stops = (key: string, role: Role) => {
      const state = this.keys.get(key);
      return state !== undefined && state.role === role && stopped.includes(state);
    };
    if (![...cutoffs.keys()].every((key) => stops(key, "device"))) return "malformed";
    if (![...reads.keys()].every((key) => stops(key, "mail"))) return "malformed";
    for (const state of stopped) {
      if (state.revoked_at === undefined) state.revoked_at = input.position;
      if (state.role === "device") state.after_seq = Math.min(state.after_seq ?? Infinity, cutoffs.get(state.key) ?? 0);
      if (state.role === "mail") {
        const listed = reads.get(state.key) ?? new Set<string>();
        state.mail_read = state.mail_read === undefined ? listed : new Set([...state.mail_read].filter((h) => listed.has(h)));
      }
    }
    return null;
  }

  private checkRetract(envelope: Envelope, body: Json | undefined): FoldError | null {
    if (!isObject(body)) return "malformed";
    const target = str(body, "target");
    if (target === undefined) return "malformed";
    const targetAuthor = this.authorOf.get(target);
    if (targetAuthor === undefined) return "malformed";
    const targetIdentity = this.identityOf(targetAuthor);
    if (this.breaks.has("retract-author")) return null;
    if (targetIdentity === undefined || targetIdentity !== this.identityOf(envelope.author)) return "retract_not_author";
    return null;
  }

  /** The admitted keys as GET /v0/circle reports them, sorted by key. */
  admittedKeys(): KeyState[] {
    return [...this.keys.values()].sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
  }
}
