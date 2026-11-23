// The reference node: what a node's sync must conclude from a set of relays, written once in the
// plainest form so the OCaml node can be held to it. It reads every relay, verifies every envelope
// (one whose signature or body_hash does not verify is an invalid_envelope fault, never folded),
// dedupes by hash, folds the union in the canonical order below, and reports the fold, the feed,
// forks and gaps. It keeps no state between runs. Its one write is replication (docs/protocol.md, The
// admission fold): it pushes each relay the dinners, joins and self-authored device messages it lacks.
//
// Canonical order (docs/protocol.md, The admission fold): the root dinner first, then repeatedly
// take, of the envelopes not yet folded, every one that folds, in (created_at, hash) order, until a
// pass folds nothing. The order is a property of the SET of
// envelopes, never of which relay answered first, which is what makes divergent histories merge to
// the same fold and feed. A revoked key is read by its revoke's cutoff, never by this order: a device
// key up to `after_seq`, a mail key by the hashes `mail_read` lists. created_at is the author's clock,
// and a thief holding the key writes it.
import "./node-crypto.ts"; // installs the node:crypto SuiteCrypto: this module only runs on Node
import { keepId, verifiedKeep } from "./bodies.ts";
import { hashOf, type Json } from "./encoding.ts";
import { envelopeHash, isCircleState, verifyEnvelope, type Envelope, type StoredEnvelope } from "./envelope.ts";
import { Fold, type FoldBreak } from "./fold.ts";
import { Signer } from "./keys.ts";
import { RelayClient } from "./request.ts";
import { openSealed, type EncryptionKey } from "./sealing.ts";

/** What `<node> sync` prints, one JSON object on stdout. Every list is sorted, so two states compare as text. */
export interface NodeState {
  epoch: number;
  keys: Array<{ key: string; role: string; identity: string; revoked: boolean }>;
  /** Content envelope hashes a person would see, in feed order: (created_at, hash). Retracts and their targets are absent. */
  feed: string[];
  /**
   * A fork names both hashes at one author's seq; an invalid_envelope names the one hash a relay served
   * whose signature or body_hash does not verify, at the author and seq the envelope claims.
   */
  faults: Array<{ kind: "fork" | "invalid_envelope"; author: string; seq: number; hashes: string[] }>;
  gaps: Array<{ author: string; missing: number[] }>;
  /**
   * The id of every Keep the node honours (docs/protocol.md, Member review), once however many
   * copies it opened: sealed to the node's encryption key, its signature by an admitted device of
   * an identity other than the member kept, bound to a key of the signer set the fold held at the
   * Keep's created_at.
   */
  keeps: string[];
}

/** Rules the reference node can be told to get wrong, so the self-test can prove each node case catches it. */
export type NodeBreak =
  | "verify"
  | "dedupe"
  | "fork"
  | "gap"
  | "backfill"
  | "revocation"
  | "cutoff"
  | "mail-cutoff"
  | "bootstrap"
  | "retract-author"
  | "mail"
  | "relay-order"
  | "self-device"
  | "device-signature"
  | "host-device-window"
  | "admin-revoke"
  | "admin-revoke-admin"
  | "replicate"
  | "join-floor"
  | "keep-admin"
  | "keep-at";

interface Held {
  hash: string;
  envelope: Envelope;
  body: Json | undefined;
}

function byTimeThenHash(a: Held, b: Held): number {
  if (a.envelope.created_at !== b.envelope.created_at) return a.envelope.created_at < b.envelope.created_at ? -1 : 1;
  return a.hash < b.hash ? -1 : a.hash > b.hash ? 1 : 0;
}

type Fault = NodeState["faults"][number];

/**
 * Keeps one copy per hash of every envelope that verifies, preferring a copy that carries its body.
 * A copy whose signature does not verify against its author, or whose body is present and does not
 * match body_hash, is never kept: it is an invalid_envelope fault, one per hash. A copy with no body
 * (a relay dropped it for a retract) verifies by its envelope alone.
 */
export function union(pages: StoredEnvelope[][], breaks: ReadonlySet<NodeBreak> = new Set()): { envelopes: Held[]; invalid: Fault[] } {
  const held = new Map<string, Held>();
  const copies: Held[] = [];
  const invalid = new Map<string, Fault>();
  for (const page of breaks.has("backfill") ? pages.slice(0, 1) : pages) {
    for (const stored of page) {
      const envelope = stored.envelope;
      const hash = envelopeHash(envelope);
      const body = stored.body === null ? undefined : stored.body;
      const verifies = breaks.has("verify") || (verifyEnvelope(envelope) && (body === undefined || hashOf(body) === envelope.body_hash));
      if (!verifies) {
        invalid.set(hash, { kind: "invalid_envelope", author: envelope.author, seq: envelope.seq, hashes: [hash] });
        continue;
      }
      if (breaks.has("dedupe")) copies.push({ hash, envelope, body });
      const existing = held.get(hash);
      if (existing === undefined || (existing.body === undefined && body !== undefined)) held.set(hash, { hash, envelope, body });
    }
  }
  return { envelopes: breaks.has("dedupe") ? copies : [...held.values()], invalid: [...invalid.values()] };
}

/** Folds the envelopes in canonical order, leaving out `excluded`. Returns the fold and what it folded, in order. */
/** The identities bound to a key of the signer set from `at` on: one per root or signer_set the fold applied, in fold order. */
interface Seats {
  at: string;
  seated: ReadonlySet<string>;
}

interface Folded {
  fold: Fold;
  folded: Held[];
  seats: Seats[];
}

function seatsOf(fold: Fold, at: string): Seats {
  const set = fold.signerSet;
  const seated = new Set<string>();
  for (const key of set?.keys ?? []) {
    const identity = set?.identities.get(key);
    if (identity !== undefined) seated.add(identity);
  }
  return { at, seated };
}

function foldInOrder(root: string, envelopes: Held[], excluded: ReadonlySet<string>, breaks: ReadonlySet<NodeBreak>): Folded {
  const foldBreaks: FoldBreak[] = [];
  if (breaks.has("revocation")) foldBreaks.push("revocation");
  if (breaks.has("bootstrap")) foldBreaks.push("spent", "expiry");
  if (breaks.has("retract-author")) foldBreaks.push("retract-author");
  if (breaks.has("mail-cutoff")) foldBreaks.push("mail-cutoff");
  if (breaks.has("self-device")) foldBreaks.push("self-device");
  if (breaks.has("device-signature")) foldBreaks.push("device-signature");
  if (breaks.has("host-device-window")) foldBreaks.push("host-device-window");
  if (breaks.has("admin-revoke")) foldBreaks.push("admin-revoke");
  if (breaks.has("admin-revoke-admin")) foldBreaks.push("admin-revoke-admin");
  // The fold holds the circle's signer set, which an admin-signed revoke is judged by (docs/protocol.md,
  // revoke): a circle root's admins, changed by each signer_set that verifies against them. A node
  // holds no release signer set the suite can name, so a dinner root starts from none and its
  // admins revoke nobody here. Admissions are never judged: the cutover is past every position.
  const fold = new Fold(root, {
    breaks: foldBreaks,
    readsCutoffs: !breaks.has("cutoff"),
    admission: { cutover: Number.MAX_SAFE_INTEGER, signers: [] },
  });
  const folded: Held[] = [];
  const seats: Seats[] = [];
  // The root first: an envelope sharing its created_at and sorting ahead of it by hash would
  // otherwise miss the first pass, and a later envelope could fold ahead of it in that pass.
  const rootFirst = (a: Held, b: Held) => (a.hash === root ? -1 : b.hash === root ? 1 : byTimeThenHash(a, b));
  let pending = envelopes.filter((h) => !excluded.has(h.hash)).sort(rootFirst);
  for (let progress = true; progress && pending.length > 0; ) {
    progress = false;
    const remaining: Held[] = [];
    for (const held of pending) {
      const position = folded.length + 1;
      const error =
        held.body === undefined && isCircleState(held.envelope.kind)
          ? "malformed"
          : held.body === undefined
            ? fold.activeAuthor(held.envelope.author, { seq: held.envelope.seq, hash: held.hash }) === undefined
              ? "not_admitted"
              : null
            : fold.apply({ hash: held.hash, envelope: held.envelope, body: held.body, position, now: new Date(held.envelope.created_at) });
      if (error === null) {
        folded.push(held);
        if (held.hash === root || held.envelope.kind === "signer_set") seats.push(seatsOf(fold, held.envelope.created_at));
        progress = true;
      } else {
        remaining.push(held);
      }
    }
    pending = remaining;
  }
  return { fold, folded, seats };
}

/**
 * Folds the union, then reads every revoked key by its cutoff: an envelope outside the cutoff
 * that folded (because its created_at put it ahead of the revoke) is left out and the union folded
 * again, until nothing folded is past a cutoff. A backdated envelope can have admitted guests or keys
 * of its own, which is why it is refolded rather than dropped from the feed.
 */
function foldUnion(root: string, envelopes: Held[], breaks: ReadonlySet<NodeBreak>): Folded {
  const excluded = new Set<string>();
  for (;;) {
    const result = foldInOrder(root, envelopes, excluded, breaks);
    if (breaks.has("cutoff")) return result;
    const past = result.folded.filter((h) => result.fold.pastCutoff(h.envelope, h.hash));
    if (past.length === 0) return result;
    for (const held of past) excluded.add(held.hash);
  }
}

/**
 * The first seq of `chain` an envelope at or past `floor` holds: below it a missing seq may be content
 * written before the reader joined, which no relay serves it (relay/src/read.ts, page). An author's
 * chain carries a non-decreasing epoch, so a missing seq above it is a gap. `undefined` when the
 * whole chain is below the floor, which expects every hole.
 */
function firstServed(floor: number, chain: Map<number, Held[]>): number | undefined {
  if (floor === 0) return 1;
  let first: number | undefined;
  for (const [seq, held] of chain) {
    if (held.some((h) => h.envelope.epoch >= floor) && (first === undefined || seq < first)) first = seq;
  }
  return first;
}

/**
 * The ids of the Keeps the fold honours, of every folded `keep` sealed to `encryption`: the Keep
 * verifies, `by` is an admitted device of an identity other than the member kept, and that identity
 * is bound to a key of the set the fold held at the Keep's created_at, the last applied whose
 * envelope is dated at or before it.
 */
function honouredKeeps({ fold, folded, seats }: Folded, encryption: EncryptionKey | undefined, breaks: ReadonlySet<NodeBreak>): string[] {
  if (encryption === undefined) return [];
  const seatedAt = (at: string, identity: string): boolean => {
    const held = breaks.has("keep-at") ? seats[seats.length - 1] : [...seats].reverse().find((s) => s.at <= at);
    return held?.seated.has(identity) ?? false;
  };
  const ids = new Set<string>();
  for (const held of folded) {
    const body = held.body;
    if (held.envelope.kind !== "keep" || typeof body !== "object" || body === null || Array.isArray(body)) continue;
    const keep = verifiedKeep(openSealed(body["sealed"], encryption));
    if (keep === undefined) continue;
    const by = fold.keys.get(keep.by);
    if (by?.role !== "device" || by.identity === keep.member) continue;
    if (breaks.has("keep-admin") || seatedAt(keep.created_at, by.identity)) ids.add(keepId(keep));
  }
  return [...ids].sort();
}

/** Computes the state `reader` concludes: its join epoch floors the gap scan (0 for a founder, and for a key the fold has not admitted). */
export function computeState(
  root: string,
  envelopes: Held[],
  invalid: Fault[],
  reader: string,
  breaks: ReadonlySet<NodeBreak> = new Set(),
  encryption?: EncryptionKey,
): NodeState {
  const result = foldUnion(root, envelopes, breaks);
  const { fold, folded } = result;
  const floor = breaks.has("join-floor") ? 0 : (fold.keys.get(reader)?.join_epoch ?? 0);

  const roleOf = (key: string) => fold.keys.get(key)?.role;
  const chains = new Map<string, Map<number, Held[]>>();
  for (const held of envelopes) {
    const role = roleOf(held.envelope.author);
    if (role !== "device" && !(role === "mail" && breaks.has("mail"))) continue;
    if (!breaks.has("cutoff") && fold.pastCutoff(held.envelope, held.hash)) continue;
    const chain = chains.get(held.envelope.author) ?? new Map<number, Held[]>();
    chain.set(held.envelope.seq, [...(chain.get(held.envelope.seq) ?? []), held]);
    chains.set(held.envelope.author, chain);
  }
  const faults: Fault[] = [...invalid];
  const gaps: NodeState["gaps"] = [];
  const forked = new Set<string>();
  for (const [author, chain] of chains) {
    for (const [seq, held] of chain) {
      const hashes = new Set(held.map((h) => h.hash));
      if (hashes.size > 1 && !breaks.has("fork")) {
        faults.push({ kind: "fork", author, seq, hashes: [...hashes].sort() });
        for (const hash of hashes) forked.add(hash);
      }
    }
    const max = Math.max(...chain.keys());
    const missing: number[] = [];
    for (let seq = firstServed(floor, chain) ?? max + 1; seq <= max; seq++) if (!chain.has(seq)) missing.push(seq);
    if (missing.length > 0 && !breaks.has("gap")) gaps.push({ author, missing });
  }

  const retracted = new Set<string>();
  for (const held of folded) {
    if (held.envelope.kind === "retract" && held.body !== undefined && typeof held.body === "object" && !Array.isArray(held.body) && held.body !== null) {
      const target = held.body["target"];
      if (typeof target === "string") retracted.add(target);
    }
  }
  const feed = folded
    .filter((h) => !isCircleState(h.envelope.kind) && h.envelope.kind !== "retract")
    .filter((h) => !retracted.has(h.hash) && !forked.has(h.hash))
    .sort(breaks.has("relay-order") ? (a, b) => envelopes.indexOf(a) - envelopes.indexOf(b) : byTimeThenHash)
    .map((h) => h.hash);

  return {
    epoch: fold.epoch,
    keys: fold.admittedKeys().map((k) => ({ key: k.key, role: k.role, identity: k.identity, revoked: k.revoked_at !== undefined })),
    feed,
    faults: faults.sort((a, b) => (`${a.author}/${a.seq}/${a.kind}` < `${b.author}/${b.seq}/${b.kind}` ? -1 : 1)),
    gaps: gaps.sort((a, b) => (a.author < b.author ? -1 : 1)),
    keeps: honouredKeeps(result, encryption, breaks),
  };
}

function isSelfAuthoredDevice(held: Held): boolean {
  const body = held.body;
  return held.envelope.kind === "device" && typeof body === "object" && body !== null && !Array.isArray(body) && body["key"] === held.envelope.author;
}

/**
 * Pushes each relay what admits other members there and it did not return, from what the fold
 * applied: every dinner, unsigned, then every join, signed by `device`, then every self-authored
 * device message, unsigned as its author's bootstrap, each in (created_at, hash) order. A refusal is
 * left for the next sync.
 */
async function replicate(device: Signer, relays: string[], pages: StoredEnvelope[][], folded: Held[]): Promise<void> {
  const dinners = folded.filter((h) => h.envelope.kind === "dinner").sort(byTimeThenHash);
  const joins = folded.filter((h) => h.envelope.kind === "join").sort(byTimeThenHash);
  const devices = folded.filter(isSelfAuthoredDevice).sort(byTimeThenHash);
  for (const [i, url] of relays.entries()) {
    const returned = new Set((pages[i] ?? []).map((stored) => envelopeHash(stored.envelope)));
    const client = new RelayClient(url, device);
    for (const held of [...dinners, ...joins, ...devices]) {
      if (returned.has(held.hash) || held.body === undefined) continue;
      await client.append({ envelope: held.envelope, body: held.body }, { unsigned: held.envelope.kind !== "join" });
    }
  }
}

/**
 * Reads every relay as `device`, replicates to each what it lacks of the admitted set, and computes
 * the state. The circle root is what the relays report.
 */
export async function sync(device: Signer, relays: string[], breaks: ReadonlySet<NodeBreak> = new Set(), encryption?: EncryptionKey): Promise<NodeState> {
  const pages: StoredEnvelope[][] = [];
  let root: string | undefined;
  for (const url of relays) {
    const client = new RelayClient(url, device);
    const circle = await client.circle();
    if (circle.status !== 200) throw new Error(`GET /v0/circle on ${url} answered ${circle.status}: ${circle.text}`);
    const relayRoot = (circle.body as { root: string }).root;
    if (root !== undefined && relayRoot !== root) throw new Error(`${url} roots ${relayRoot}, not ${root}`);
    root = relayRoot;
    pages.push(await client.fetchAll());
  }
  if (root === undefined) throw new Error("no relays");
  const { envelopes, invalid } = union(pages, breaks);
  if (!breaks.has("replicate")) await replicate(device, relays, pages, foldUnion(root, envelopes, breaks).folded);
  return computeState(root, envelopes, invalid, device.key, breaks, encryption);
}
