// The admission fold, docs/protocol.md "The admission fold". One implementation shared by the fake
// relay (folding in relay order) and the reference node (folding the union of relays in its
// canonical order), so the two can never disagree about who is admitted.
import { jcs, type Json } from "./encoding.ts";
import { verifySignature } from "./keys.ts";
import { isCircleState, type Envelope } from "./envelope.ts";
import { SignerSet } from "./admission.ts";

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
  /**
   * The time an invite's expiry and the host device's revoke window are judged against: on a relay
   * its own clock, or a join's created_at when an admitted member pushed it; on a node the
   * envelope's created_at (docs/protocol.md, The admission fold).
   */
  now: Date;
  /**
   * The envelope was accepted when it arrived and is being replayed from a log: its dinner's
   * admissions are not judged again, since the signer set a relay starts from changes with the
   * relay release it runs, and a log that held an admission must refold whatever set judges it now.
   * Nor are the key signatures inside a join, device or revoke verified again: the fold verified
   * them when it accepted the envelope, and a replay that re-verified them would spend about three
   * Ed25519 verifies per member on every append (DIG-217). Every other rule still runs.
   */
  stored?: boolean;
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
export type FoldBreak =
  | "expiry"
  | "spent"
  | "revocation"
  | "retract-author"
  | "cutoff-shape"
  | "mail-cutoff"
  | "self-device"
  | "device-signature"
  | "host-device-dinner"
  | "host-device-window"
  | "release-revocation-shape"
  | "release-recall-shape"
  | "relay-release-shape"
  | "signer-set-shape"
  | "prompt-shape";

/**
 * How long after a join the device key that wrote its dinner may revoke the identity the join
 * admitted: the join choice's 72 hours, and room for a host's node that was asleep at its deadline.
 */
export const HOST_DEVICE_REVOKE_WINDOW_MS = 7 * 24 * 3600 * 1000;

export interface FoldOptions {
  breaks?: Iterable<FoldBreak>;
  /**
   * A node reads a revoked key by its cutoff, wherever the envelope sits in the fold: a device key at
   * or below `after_seq` and none above, a mail key the envelopes `mail_read` lists and no other. A
   * relay leaves this off and refuses every append from a revoked key from the revoke on.
   */
  readsCutoffs?: boolean;
  /**
   * docs/protocol.md, The admission fold: a dinner after `cutover` records its guests only when each
   * carries an admission every key of the folded signer set signed, and none while a revoked key is
   * in that set. The set starts from `signers` (a relay's build's release-signers.json), or from the
   * `admins` a circle root names, and changes by each signer_set and release_revocation that
   * verifies against it. Absent: every dinner
   * admits by its guests' invite keys alone, the rule before the cutover.
   */
  admission?: { cutover: number; signers: string[] };
}

export class Fold {
  readonly root: string;
  readonly breaks: ReadonlySet<FoldBreak>;
  readonly readsCutoffs: boolean;
  /** The admission cutover, when the fold judges admissions. */
  readonly admissionCutover: number | undefined;
  /**
   * The signer set dinners after the cutover are judged by, when the fold judges admissions: the
   * one the fold was given, until a circle root naming `admins` replaces it with those.
   */
  signerSet: SignerSet | undefined;
  rootFolded = false;
  epoch = 0;
  readonly keys = new Map<string, KeyState>();
  private readonly invites = new Map<string, Invite>();
  /** Dinner hash to the identity of the host who wrote it. */
  private readonly dinners = new Map<string, string>();
  /** Identity to the host identity whose dinner admitted it. */
  private readonly admittedBy = new Map<string, string>();
  /** Dinner hash to the device key that wrote it. */
  private readonly dinnerAuthors = new Map<string, string>();
  /** Identity to the dinner its join named and the time the join was judged at. */
  private readonly joins = new Map<string, { dinner: string; at: number }>();
  /** Envelope hash to its author key, for the retract rule. */
  private readonly authorOf = new Map<string, string>();

  constructor(root: string, options: FoldOptions = {}) {
    this.root = root;
    this.breaks = new Set(options.breaks ?? []);
    this.readsCutoffs = options.readsCutoffs ?? false;
    this.admissionCutover = options.admission?.cutover;
    this.signerSet = options.admission === undefined ? undefined : new SignerSet(options.admission.signers);
  }

  /**
   * An independent copy: applying to it changes nothing of this fold, so a fold kept between
   * appends can be handed to one and still describe the log it was built from.
   */
  clone(): Fold {
    const signers = this.signerSet;
    const copy = new Fold(this.root, {
      breaks: this.breaks,
      readsCutoffs: this.readsCutoffs,
      ...(signers === undefined ? {} : { admission: { cutover: this.admissionCutover ?? 0, signers: signers.keys } }),
    });
    for (const key of signers?.revoked ?? []) copy.signerSet?.revoked.add(key);
    copy.rootFolded = this.rootFolded;
    copy.epoch = this.epoch;
    for (const [key, state] of this.keys) {
      copy.keys.set(key, { ...state, ...(state.mail_read === undefined ? {} : { mail_read: new Set(state.mail_read) }) });
    }
    for (const [key, invite] of this.invites) copy.invites.set(key, { ...invite });
    for (const [k, v] of this.dinners) copy.dinners.set(k, v);
    for (const [k, v] of this.admittedBy) copy.admittedBy.set(k, v);
    for (const [k, v] of this.dinnerAuthors) copy.dinnerAuthors.set(k, v);
    for (const [k, v] of this.joins) copy.joins.set(k, { ...v });
    for (const [k, v] of this.authorOf) copy.authorOf.set(k, v);
    return copy;
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

  /** The fold's state for a key, revoked or not; undefined for a key no envelope admitted. */
  keyState(key: string): KeyState | undefined {
    return this.keys.get(key);
  }

  /** True when a dinner the fold accepted lists this invite key, open, spent or expired. */
  hasInvite(key: string): boolean {
    return this.invites.has(key);
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
      if (!isRootKind(envelope.kind) || input.hash !== this.root) return "wrong_circle";
      return this.foldRoot(input);
    }
    // A circle envelope is only ever a root: any other names a circle this one is not.
    if (envelope.kind === "circle") return "wrong_circle";
    if (!isCircleState(envelope.kind) || envelope.kind === "card" || envelope.kind === "relay" || envelope.kind === "release_revocation" || envelope.kind === "release_recall" || envelope.kind === "relay_release" || envelope.kind === "signer_set" || envelope.kind === "prompt") {
      if (this.activeAuthor(envelope.author, { seq: envelope.seq, hash: input.hash }) === undefined) return "not_admitted";
      if (envelope.kind === "retract") return this.checkRetract(envelope, body);
      if (envelope.kind === "release_revocation") return this.foldReleaseRevocation(body);
      if (envelope.kind === "release_recall") return this.checkReleaseDocument(body, "release-recall-shape");
      if (envelope.kind === "relay_release") return this.checkReleaseDocument(body, "relay-release-shape");
      if (envelope.kind === "signer_set") return this.foldSignerSet(body);
      if (envelope.kind === "prompt") return this.checkPrompt(body);
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

  /**
   * docs/protocol.md, release_revocation, release_recall, relay_release and signer_set: release keys are not
   * circle keys, so the fold checks only that the body carries a string `document` and a list of
   * `signatures`; the node verifies them against its own release signer set, and a fold that judges
   * admissions folds a signer_set and a release_revocation into its own (foldSignerSet,
   * foldReleaseRevocation).
   */
  private checkReleaseDocument(body: Json | undefined, skip: FoldBreak): FoldError | null {
    if (this.breaks.has(skip)) return null;
    if (!isObject(body) || typeof body["document"] !== "string" || !Array.isArray(body["signatures"])) return "malformed";
    return null;
  }

  /** A release_revocation of the right shape, honored by the signer set when one of its keys signed it. */
  private foldReleaseRevocation(body: Json | undefined): FoldError | null {
    const error = this.checkReleaseDocument(body, "release-revocation-shape");
    if (error === null) this.signerSet?.revoke(body);
    return error;
  }

  /** A signer_set of the right shape, adopted only when it verifies against the set the fold holds: posting one grants nothing. */
  private foldSignerSet(body: Json | undefined): FoldError | null {
    const error = this.checkReleaseDocument(body, "signer-set-shape");
    if (error === null) this.signerSet?.adopt(body);
    return error;
  }

  /**
   * docs/protocol.md, The admission fold, step 2: after the cutover every guest entry carries an
   * admission the whole signer set signed, for this circle and that invite key, and none counts
   * while a revoked key is in the set. A dinner with one entry that does not is refused whole, so
   * a stale node's unsigned dinner admits nobody. A shape fault is left to recordGuests.
   */
  private checkAdmissions(input: FoldInput, body: { [key: string]: Json }): FoldError | null {
    const set = this.signerSet;
    if (set === undefined || input.stored || input.position <= (this.admissionCutover ?? 0)) return null;
    const guests = body["guests"];
    if (!Array.isArray(guests)) return null;
    for (const guest of guests) {
      if (!isObject(guest)) return null;
      const invite = str(guest, "invite_key");
      if (invite === undefined) return null;
      if (!set.admits(guest["admission"], this.root, invite)) return "not_admitted";
    }
    return null;
  }

  /** docs/protocol.md, prompt: the circle's live note prompt changes no admission; its body names the suggestion and carries the text. */
  private checkPrompt(body: Json | undefined): FoldError | null {
    if (this.breaks.has("prompt-shape")) return null;
    if (!isObject(body) || typeof body["suggestion"] !== "string" || typeof body["text"] !== "string") return "malformed";
    return null;
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
    if (envelope.kind === "circle" && circleName(body) === undefined) return "malformed";
    const admins = envelope.kind === "circle" ? circleAdmins(body) : null;
    if (admins === undefined) return "malformed";
    // A circle root may list no guests: its founder invites them later, in a dinner.
    const guestError = envelope.kind === "circle" && body["guests"] === undefined ? null : this.recordGuests(input.hash, body);
    if (guestError !== null) return guestError;
    this.rootFolded = true;
    // A circle that names its own admins is judged by them, never by the release signers.
    if (admins !== null && this.signerSet !== undefined) this.signerSet = new SignerSet(admins);
    this.dinners.set(input.hash, host);
    this.dinnerAuthors.set(input.hash, envelope.author);
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
    const admissionError = this.checkAdmissions(input, body);
    if (admissionError !== null) return admissionError;
    const guestError = this.recordGuests(input.hash, body);
    if (guestError !== null) return guestError;
    this.dinners.set(input.hash, author.identity);
    this.dinnerAuthors.set(input.hash, author.key);
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
    if (!input.stored) {
      if (!verifySignature(inviteKey, jcs({ dinner, identity_key: identity }), identitySignature)) return "bad_signature";
      if (!verifySignature(identity, jcs({ identity_key: identity, device_key: device, role: "device" }), deviceSignature)) {
        return "bad_signature";
      }
    }
    if ((this.keys.has(identity) || this.keys.has(device)) && !this.breaks.has("spent")) return "not_admitted";
    invite.spent = true;
    this.epoch += 1;
    const host = this.dinners.get(dinner);
    if (host !== undefined) this.admittedBy.set(identity, host);
    this.joins.set(identity, { dinner, at: input.now.getTime() });
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
    if (!input.stored && !verifySignature(identity, jcs({ identity_key: identity, key, role }), signature) && !this.breaks.has("device-signature")) {
      return "bad_signature";
    }
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
    const byState = this.keys.get(by);
    if (byState === undefined) return "not_admitted";
    if (byState.role === "identity") {
      if (author.identity !== by || byState.revoked_at !== undefined) return "not_admitted";
    } else if (byState.role !== "device" || author.key !== by) {
      // A device key revokes as itself, never on another key's behalf; a mail key revokes nothing.
      return "not_admitted";
    }
    const signed = {
      target,
      by,
      ...(body["after_seq"] === undefined ? {} : { after_seq: body["after_seq"] }),
      ...(body["mail_read"] === undefined ? {} : { mail_read: body["mail_read"] }),
    };
    if (!input.stored && !verifySignature(by, jcs(signed), signature)) return "bad_signature";
    const targetState = this.keys.get(target);
    if (targetState === undefined) return "not_admitted";
    if (targetState.role === "identity") {
      if (byState.role === "device") {
        if (!this.dinnerDeviceMayRevoke(by, target, input.now)) return "not_admitted";
      } else if (by !== target && by !== this.admittedBy.get(target)) {
        return "not_admitted";
      }
    } else if (byState.role !== "identity" || targetState.identity !== by) {
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

  /**
   * The device key that wrote a dinner may revoke an identity a join on that dinner admitted, within
   * HOST_DEVICE_REVOKE_WINDOW_MS of the join: how the host's node revokes an unpicked join choice
   * without the recovery phrase. A relay judges it by its own clock, a node by the two created_at.
   */
  private dinnerDeviceMayRevoke(device: string, identity: string, now: Date): boolean {
    const join = this.joins.get(identity);
    if (join === undefined) return false;
    if (this.dinnerAuthors.get(join.dinner) !== device && !this.breaks.has("host-device-dinner")) return false;
    return now.getTime() <= join.at + HOST_DEVICE_REVOKE_WINDOW_MS || this.breaks.has("host-device-window");
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

/**
 * docs/protocol.md, circle and dinner: a circle's root is a `circle` envelope, which names the circle
 * and its founder, or, for a circle founded at a dinner, that `dinner`.
 */
export function isRootKind(kind: string): boolean {
  return kind === "circle" || kind === "dinner";
}

/** The non-blank name a `circle` body carries in `circle.name`. */
export function circleName(body: { [key: string]: Json }): string | undefined {
  const circle = body["circle"];
  if (typeof circle !== "object" || circle === null || Array.isArray(circle)) return undefined;
  const name = circle["name"];
  return typeof name === "string" && name.trim() !== "" ? name : undefined;
}

/**
 * The keys a `circle` body's `admins` names (docs/protocol.md, circle): the circle's own signer set.
 * null when the body names none; undefined when `admins` is not a non-empty list of `{ name, key }`
 * with an ed25519 key, none twice.
 */
export function circleAdmins(body: { [key: string]: Json }): string[] | null | undefined {
  const admins = body["admins"];
  if (admins === undefined) return null;
  if (!Array.isArray(admins) || admins.length === 0) return undefined;
  const keys: string[] = [];
  for (const a of admins) {
    if (!isObject(a) || typeof a["name"] !== "string" || typeof a["key"] !== "string" || !a["key"].startsWith("ed25519:")) return undefined;
    keys.push(a["key"]);
  }
  return new Set(keys).size === keys.length ? keys : undefined;
}
